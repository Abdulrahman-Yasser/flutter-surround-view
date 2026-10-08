#include "still_camera.h"

#include <libcamera/libcamera.h>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

#include <dlfcn.h>
#include <sys/mman.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <algorithm>
#include <map>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>

using namespace libcamera;

namespace {

std::atomic<int> g_managers{0};

// libbev_view.so is dlopen'ed RTLD_LOCAL by the Dart runtime, so its symbols
// are only reachable through its own handle. RTLD_NOLOAD never loads it.
bool view_library_has_cameras()
{
    void *h = dlopen("libbev_view.so", RTLD_NOW | RTLD_NOLOAD);
    if (!h) return false;
    auto active = reinterpret_cast<int32_t (*)()>(dlsym(h, "bev_camera_manager_active"));
    const bool busy = active && active();
    dlclose(h);
    return busy;
}

std::shared_ptr<CameraManager> acquire_manager()
{
    static std::mutex mutex;
    static std::weak_ptr<CameraManager> shared;

    std::lock_guard<std::mutex> lock(mutex);
    if (auto cm = shared.lock()) return cm;

    // A view being disposed releases its cameras on another thread.
    for (int i = 0; view_library_has_cameras(); ++i) {
        if (i == 100) throw std::runtime_error("the live camera view still holds the cameras");
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    auto cm = std::make_unique<CameraManager>();
    if (cm->start()) throw std::runtime_error("CameraManager::start failed");
    ++g_managers;
    std::shared_ptr<CameraManager> started(cm.release(), [](CameraManager *c) {
        c->stop();
        delete c;
        --g_managers;
    });
    shared = started;
    return started;
}

// What a still can be read as, best first. The Pi's ISP gives YUV420; USB
// (UVC) cameras usually only offer YUYV, and MJPEG for their large sizes.
const PixelFormat kStillFormats[] = {
    formats::YUV420, formats::NV12, formats::NV21, formats::YUYV, formats::UYVY,
    formats::MJPEG, formats::RGB888, formats::BGR888, formats::XRGB8888,
};

} // namespace

int still_camera_manager_count() { return g_managers.load(); }

struct StillCamera::Impl {
    std::shared_ptr<CameraManager> cm;
    std::shared_ptr<Camera> camera;
    std::unique_ptr<CameraConfiguration> config;
    std::unique_ptr<FrameBufferAllocator> allocator;
    std::vector<std::unique_ptr<Request>> requests;
    std::map<const FrameBuffer *, std::vector<uint8_t *>> planes;
    std::vector<std::pair<void *, size_t>> maps;
    Stream *stream = nullptr;
    PixelFormat format;
    unsigned width = 0, height = 0, stride = 0;
    bool acquired = false, started = false;

    std::mutex mutex;
    std::condition_variable cv;
    std::deque<Request *> done;

    // Also unwinds a constructor that threw halfway.
    ~Impl()
    {
        if (started) camera->stop();
        if (camera) camera->requestCompleted.disconnect(this, &Impl::completed);
        requests.clear();
        for (auto &m : maps) munmap(m.first, m.second);
        allocator.reset();
        if (acquired) camera->release();
        camera.reset();
    }

    void completed(Request *req)
    {
        if (req->status() == Request::RequestCancelled) return;
        {
            std::lock_guard<std::mutex> lock(mutex);
            done.push_back(req);
        }
        cv.notify_one();
    }

    void requeue(Request *req)
    {
        req->reuse(Request::ReuseBuffers);
        camera->queueRequest(req);
    }

    void map_buffers()
    {
        for (const std::unique_ptr<FrameBuffer> &fb : allocator->buffers(stream)) {
            std::map<int, uint8_t *> base;
            std::vector<uint8_t *> ptrs;
            for (const FrameBuffer::Plane &p : fb->planes()) {
                const int fd = p.fd.get();
                if (!base.count(fd)) {
                    const size_t len = (size_t)lseek(fd, 0, SEEK_END);
                    void *m = mmap(nullptr, len, PROT_READ, MAP_SHARED, fd, 0);
                    if (m == MAP_FAILED) throw std::runtime_error("mmap of a camera buffer failed");
                    maps.emplace_back(m, len);
                    base[fd] = static_cast<uint8_t *>(m);
                }
                ptrs.push_back(base[fd] + p.offset);
            }
            planes[fb.get()] = ptrs;
        }
    }

    cv::Mat to_bgr(Request *req)
    {
        const FrameBuffer *fb = req->buffers().begin()->second;
        const std::vector<uint8_t *> &p = planes.at(fb);
        const int w = (int)width, h = (int)height;
        cv::Mat bgr;
        if (format == formats::MJPEG) {
            const size_t used = fb->metadata().planes()[0].bytesused;
            bgr = cv::imdecode(cv::Mat(1, (int)used, CV_8UC1, p[0]), cv::IMREAD_COLOR);
            if (bgr.empty()) throw std::runtime_error("camera sent a JPEG that doesn't decode");
            return bgr;
        }
        if (format == formats::YUYV || format == formats::UYVY) {
            cv::cvtColor(cv::Mat(h, w, CV_8UC2, p[0], stride), bgr,
                         format == formats::YUYV ? cv::COLOR_YUV2BGR_YUYV : cv::COLOR_YUV2BGR_UYVY);
            return bgr;
        }
        // DRM byte order: RGB888 is stored B, G, R and BGR888 R, G, B.
        if (format == formats::RGB888) return cv::Mat(h, w, CV_8UC3, p[0], stride).clone();
        if (format == formats::BGR888) {
            cv::cvtColor(cv::Mat(h, w, CV_8UC3, p[0], stride), bgr, cv::COLOR_RGB2BGR);
            return bgr;
        }
        if (format == formats::XRGB8888) {
            cv::cvtColor(cv::Mat(h, w, CV_8UC4, p[0], stride), bgr, cv::COLOR_BGRA2BGR);
            return bgr;
        }
        if (format == formats::NV12 || format == formats::NV21) {
            cv::Mat nv((int)(height * 3 / 2), w, CV_8UC1);
            const uint8_t *uv = p.size() > 1 ? p[1] : p[0] + stride * height;
            for (unsigned r = 0; r < height; ++r) std::memcpy(nv.ptr(r), p[0] + r * stride, width);
            for (unsigned r = 0; r < height / 2; ++r) std::memcpy(nv.ptr(h + r), uv + r * stride, width);
            cv::cvtColor(nv, bgr, format == formats::NV12 ? cv::COLOR_YUV2BGR_NV12 : cv::COLOR_YUV2BGR_NV21);
            return bgr;
        }
        // The Y plane is followed by U then V at half the stride; copy them
        // packed into the I420 layout cvtColor expects.
        const unsigned cw = width / 2, ch = height / 2, cs = stride / 2;
        cv::Mat i420((int)(height * 3 / 2), (int)width, CV_8UC1);
        uint8_t *dst = i420.data;
        const uint8_t *y = p[0];
        const uint8_t *u = p.size() > 1 ? p[1] : y + stride * height;
        const uint8_t *v = p.size() > 2 ? p[2] : u + cs * ch;
        for (unsigned r = 0; r < height; ++r, dst += width) std::memcpy(dst, y + r * stride, width);
        for (unsigned r = 0; r < ch; ++r, dst += cw) std::memcpy(dst, u + r * cs, cw);
        for (unsigned r = 0; r < ch; ++r, dst += cw) std::memcpy(dst, v + r * cs, cw);
        cv::cvtColor(i420, bgr, cv::COLOR_YUV2BGR_I420);
        return bgr;
    }
};

std::vector<StillCamera::Info> StillCamera::list()
{
    // Held for the whole loop: a temporary in the range expression would be
    // destroyed before the body runs, stopping the manager under the cameras.
    const std::shared_ptr<CameraManager> cm = acquire_manager();
    std::vector<Info> out;
    for (const std::shared_ptr<Camera> &cam : cm->cameras()) {
        const auto model = cam->properties().get(properties::Model);
        out.push_back({cam->id(), model ? std::string(*model) : cam->id()});
    }
    return out;
}

StillCamera::StillCamera(const std::string &id) : impl_(std::make_unique<Impl>())
{
    Impl &d = *impl_;
    d.cm = acquire_manager();
    d.camera = d.cm->get(id);
    if (!d.camera) throw std::runtime_error("camera " + id + " is not connected");
    // Same wait as the view's acquire_camera(): a released camera can take a
    // moment to come free after its owner was torn down.
    for (int i = 0; d.camera->acquire() != 0; ++i) {
        if (i == 100) throw std::runtime_error("camera " + id + " is in use");
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    d.acquired = true;

    d.config = d.camera->generateConfiguration({StreamRole::StillCapture});
    if (!d.config) throw std::runtime_error("no still configuration");
    StreamConfiguration &sc = d.config->at(0);
    const StreamFormats &offered = sc.formats();
    const auto fmt = std::find_if(std::begin(kStillFormats), std::end(kStillFormats), [&](const PixelFormat &f) {
        return !offered.sizes(f).empty();
    });
    if (fmt == std::end(kStillFormats)) {
        std::string have;
        for (const PixelFormat &f : offered.pixelformats()) have += " " + f.toString();
        throw std::runtime_error("camera offers no format stills can be read from (it has" + have + ")");
    }
    sc.pixelFormat = *fmt;
    // A Pi sensor reports its full pixel array; a USB camera doesn't, so take
    // the largest size it offers in this format.
    if (auto full = d.camera->properties().get(properties::PixelArraySize)) {
        sc.size = *full;
    } else {
        const std::vector<Size> sizes = offered.sizes(*fmt);
        sc.size = *std::max_element(sizes.begin(), sizes.end(), [](const Size &a, const Size &b) {
            return a.width * a.height < b.width * b.height;
        });
    }
    sc.bufferCount = 2;
    if (d.config->validate() == CameraConfiguration::Invalid || sc.pixelFormat != *fmt)
        throw std::runtime_error("camera rejected " + fmt->toString() + " stills");
    if (d.camera->configure(d.config.get())) throw std::runtime_error("camera configure failed");

    d.stream = sc.stream();
    d.format = sc.pixelFormat;
    d.width = sc.size.width;
    d.height = sc.size.height;
    d.stride = sc.stride;
    d.allocator = std::make_unique<FrameBufferAllocator>(d.camera);
    if (d.allocator->allocate(d.stream) < 0) throw std::runtime_error("buffer allocation failed");
    d.map_buffers();
    for (const std::unique_ptr<FrameBuffer> &fb : d.allocator->buffers(d.stream)) {
        std::unique_ptr<Request> req = d.camera->createRequest();
        if (!req || req->addBuffer(d.stream, fb.get())) throw std::runtime_error("request setup failed");
        d.requests.push_back(std::move(req));
    }

    d.camera->requestCompleted.connect(&d, &Impl::completed);
    if (d.camera->start()) throw std::runtime_error("camera start failed");
    d.started = true;
    for (auto &req : d.requests) d.camera->queueRequest(req.get());
}

StillCamera::~StillCamera() = default;

cv::Size StillCamera::size() const { return {(int)impl_->width, (int)impl_->height}; }

cv::Mat StillCamera::settled(int min_frames, double max_seconds)
{
    const auto end = std::chrono::steady_clock::now() + std::chrono::duration<double>(max_seconds);
    cv::Mat frame = grab();
    cv::Scalar last = cv::mean(frame);
    for (int n = 1;; ++n) {
        frame = grab();
        const cv::Scalar now = cv::mean(frame);
        double change = 0;
        for (int c = 0; c < 3; ++c) change = std::max(change, std::abs(now[c] - last[c]));
        last = now;
        if (n >= min_frames && change < 1.5) break;
        if (std::chrono::steady_clock::now() > end) break;
    }
    return frame;
}

cv::Mat StillCamera::grab(int timeout_ms)
{
    Impl &d = *impl_;
    std::unique_lock<std::mutex> lock(d.mutex);
    if (!d.cv.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&] { return !d.done.empty(); }))
        throw std::runtime_error("no frame from the camera");
    Request *newest = d.done.back();
    d.done.pop_back();
    std::deque<Request *> older;
    older.swap(d.done);
    lock.unlock();

    for (Request *r : older) d.requeue(r);
    cv::Mat bgr = d.to_bgr(newest);
    d.requeue(newest);
    return bgr;
}
