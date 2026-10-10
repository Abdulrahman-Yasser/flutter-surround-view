#include "cpu_frames.h"

#include <libcamera/formats.h>
#include <linux/dma-buf.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <cstring>
#include <set>

using namespace libcamera;

bool CpuFrames::readable(const PixelFormat &format)
{
    return format == formats::NV12 || format == formats::YUYV || format == formats::UYVY;
}

CpuFrames::~CpuFrames()
{
    for (auto &m : mmaps_) munmap(m.first, m.second);
}

bool CpuFrames::map(const std::vector<std::unique_ptr<FrameBuffer>> &buffers, const StreamConfiguration &sc)
{
    format_ = sc.pixelFormat;
    width_ = (int)sc.size.width;
    height_ = (int)sc.size.height;
    stride_ = (int)sc.stride;
    for (const std::unique_ptr<FrameBuffer> &fb : buffers) {
        std::map<int, const uint8_t *> base;
        Map m;
        for (const FrameBuffer::Plane &p : fb->planes()) {
            const int fd = p.fd.get();
            if (!base.count(fd)) {
                const size_t len = (size_t)lseek(fd, 0, SEEK_END);
                void *addr = mmap(nullptr, len, PROT_READ, MAP_SHARED, fd, 0);
                if (addr == MAP_FAILED) return false;
                mmaps_.emplace_back(addr, len);
                base[fd] = static_cast<const uint8_t *>(addr);
                m.fds.push_back(fd);
            }
            m.planes.push_back(base[fd] + p.offset);
        }
        maps_[fb.get()] = m;
    }
    if (format_ != formats::NV12) nv12_.resize((size_t)width_ * height_ * 3 / 2);
    return true;
}

// Packed 4:2:2 (two pixels in four bytes) to NV12: luma as is, chroma
// averaged over each pair of rows.
static void packed422_to_nv12(const uint8_t *src, int stride, int w, int h, bool yuyv, uint8_t *dst)
{
    const int y0 = yuyv ? 0 : 1, u0 = yuyv ? 1 : 0, v0 = yuyv ? 3 : 2;
    uint8_t *uv = dst + (size_t)w * h;
    for (int y = 0; y < h; ++y) {
        const uint8_t *s = src + (size_t)y * stride;
        uint8_t *d = dst + (size_t)y * w;
        for (int x = 0; x < w; ++x) d[x] = s[2 * x + y0];
    }
    for (int y = 0; y + 1 < h; y += 2) {
        const uint8_t *a = src + (size_t)y * stride, *b = a + stride;
        uint8_t *d = uv + (size_t)(y / 2) * w;
        for (int i = 0; i < w / 2; ++i) {
            d[2 * i]     = (uint8_t)((a[4 * i + u0] + b[4 * i + u0] + 1) / 2);
            d[2 * i + 1] = (uint8_t)((a[4 * i + v0] + b[4 * i + v0] + 1) / 2);
        }
    }
}

DmaBufFrame CpuFrames::nv12(const FrameBuffer *buf)
{
    DmaBufFrame f;
    auto it = maps_.find(buf);
    if (it == maps_.end()) return f;
    const Map &m = it->second;

    // The camera wrote these through DMA; make the CPU's view of them current.
    for (int fd : m.fds) {
        dma_buf_sync sync{DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ};
        ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync);
    }
    f.width = width_;
    f.height = height_;
    if (format_ == formats::NV12) {
        f.data = m.planes[0];
        f.stride = stride_;
        f.y_offset = 0;
        f.uv_offset = (int)(m.planes.size() > 1 ? m.planes[1] - m.planes[0] : (ptrdiff_t)stride_ * height_);
    } else {
        packed422_to_nv12(m.planes[0], stride_, width_, height_, format_ == formats::YUYV, nv12_.data());
        f.data = nv12_.data();
        f.stride = width_;
        f.y_offset = 0;
        f.uv_offset = width_ * height_;
    }
    for (int fd : m.fds) {
        dma_buf_sync sync{DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ};
        ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync);
    }
    return f;
}
