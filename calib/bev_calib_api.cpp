#include "bev_calib_api.h"

#include "bev_config.h"
#include "calib_session.h"
#include "intrinsics.h"
#include "still_camera.h"

#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

#include <cstring>
#include <exception>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

struct BevCalibSession {
    std::mutex mutex;
    std::unique_ptr<CalibSession> session;
    std::vector<std::string> camera_ids;   // per layout camera, from bev_config.ini
    std::vector<CalibSeam> seams;
};

struct BevCalibIntrinsics {
    std::mutex mutex;
    std::unique_ptr<StillCamera> camera;
    std::unique_ptr<IntrinsicsCalib> calib;
    IntrinsicsShot last;
    cv::Size last_size;
    IntrinsicsResult result;
};

static thread_local std::string t_error;

static int32_t fail(const std::string &msg)
{
    t_error = msg;
    return 0;
}

// Runs fn, turning a C++ exception into a 0 return and t_error.
template <typename Fn>
static int32_t guarded(Fn fn)
{
    try {
        return fn();
    } catch (const std::exception &e) {
        return fail(e.what());
    }
}

static void copy_str(char *dst, size_t cap, const std::string &src)
{
    std::strncpy(dst, src.c_str(), cap - 1);
    dst[cap - 1] = '\0';
}

static bool bad_cam(BevCalibSession *s, int32_t cam)
{
    if (s && cam >= 0 && cam < s->session->cameras()) return false;
    t_error = "no such camera in this layout";
    return true;
}

extern "C" {

const char *bev_calib_last_error(void) { return t_error.c_str(); }

int32_t bev_calib_camera_active(void) { return still_camera_manager_count() > 0; }

int32_t bev_calib_cameras_present(void)
{
    try {
        return (int32_t)StillCamera::list().size();
    } catch (const std::exception &e) {
        t_error = e.what();
        return -1;
    }
}

int32_t bev_calib_camera_list(BevCalibCameraEntry *out, int32_t cap)
{
    try {
        const std::vector<StillCamera::Info> cams = StillCamera::list();
        for (size_t i = 0; i < cams.size() && (int32_t)i < cap; ++i) {
            copy_str(out[i].id, sizeof(out[i].id), cams[i].id);
            copy_str(out[i].model, sizeof(out[i].model), cams[i].model);
        }
        return (int32_t)cams.size();
    } catch (const std::exception &e) {
        t_error = e.what();
        return -1;
    }
}

int32_t bev_calib_camera_snapshot(const char *camera_id, const char *jpeg_path, int32_t width)
{
    return guarded([&] {
        cv::Mat frame;
        {
            StillCamera camera(camera_id);
            frame = camera.settled(8);
        }
        const double scale = (double)width / frame.cols;
        cv::Mat small;
        cv::resize(frame, small, {}, scale, scale, cv::INTER_AREA);
        return cv::imwrite(jpeg_path, small) ? 1 : fail(std::string("cannot write ") + jpeg_path);
    });
}

const char *bev_calib_position_name(int32_t position)
{
    const char *name = bev_position_name(position);
    return name ? name : "";
}

int32_t bev_calib_config_position(const char *config_path, int32_t position, BevCalibPosition *out)
{
    if (!bev_position_name(position)) return fail("no such position");
    BevConfig cfg;
    if (!bev_config_load(config_path, cfg)) return fail(std::string("malformed ") + config_path);
    const BevSlotConfig &s = cfg.slots[position];
    copy_str(out->camera, sizeof(out->camera), s.camera);
    copy_str(out->lens, sizeof(out->lens), s.lens_model);
    out->calibrated = s.has_hb2i;
    return 1;
}

int32_t bev_calib_config_assign(const char *config_path, int32_t position, const char *camera_id)
{
    if (!bev_position_name(position)) return fail("no such position");
    BevConfig cfg;
    if (!bev_config_load(config_path, cfg)) return fail(std::string("malformed ") + config_path);
    const std::string id = camera_id ? camera_id : "";
    if (!id.empty())
        for (BevSlotConfig &s : cfg.slots)
            if (s.camera == id) s.camera.clear();
    cfg.slots[position].camera = id;
    return bev_config_save(config_path, cfg) ? 1 : fail(std::string("cannot write ") + config_path);
}

int32_t bev_calib_layout_info(const char *path, BevCalibLayoutInfo *out)
{
    CalibLayout l;
    if (!calib_layout_load(path, l)) return fail(std::string("bad layout ") + path);
    copy_str(out->name, sizeof(out->name), l.name);
    out->car_width = l.car_width;
    out->car_length = l.car_length;
    out->cameras = (int32_t)l.cameras.size();
    out->boards = (int32_t)l.boards.size();
    return 1;
}

int32_t bev_calib_layout_camera(const char *path, int32_t index, BevCalibCameraInfo *out)
{
    CalibLayout l;
    if (!calib_layout_load(path, l)) return fail(std::string("bad layout ") + path);
    if (index < 0 || index >= (int32_t)l.cameras.size()) return fail("no such camera");
    const CalibCamera &c = l.cameras[(size_t)index];
    out->position = c.position;
    out->facing_deg = c.facing_deg;
    copy_str(out->lens, sizeof(out->lens), c.lens);
    return 1;
}

int32_t bev_calib_layout_board(const char *path, int32_t index, BevCalibBoardInfo *out)
{
    CalibLayout l;
    if (!calib_layout_load(path, l)) return fail(std::string("bad layout ") + path);
    if (index < 0 || index >= (int32_t)l.boards.size()) return fail("no such board");
    const CalibBoard &b = l.boards[(size_t)index];
    copy_str(out->dict, sizeof(out->dict), b.dict);
    out->squares_x = b.squares_x;
    out->squares_y = b.squares_y;
    out->first_id = b.first_id;
    out->square_len = b.square_len;
    out->marker_len = b.marker_len;
    out->x = b.x;
    out->y = b.y;
    out->yaw_deg = b.yaw_deg;
    out->square = b.square;
    return 1;
}

int32_t bev_calib_config_set_lens(const char *config_path, int32_t position, const char *lens)
{
    if (!bev_position_name(position)) return fail("no such position");
    BevConfig cfg;
    if (!bev_config_load(config_path, cfg)) return fail(std::string("malformed ") + config_path);
    cfg.slots[position].lens_model = lens ? lens : "";
    return bev_config_save(config_path, cfg) ? 1 : fail(std::string("cannot write ") + config_path);
}

BevCalibSession *bev_calib_open(const char *layout_path, const char *lens_dir, const char *config_path)
{
    CalibLayout l;
    if (!calib_layout_load(layout_path, l)) {
        fail(std::string("bad layout ") + layout_path);
        return nullptr;
    }
    BevConfig cfg;
    if (!bev_config_load(config_path, cfg)) {
        fail(std::string("malformed ") + config_path);
        return nullptr;
    }
    try {
        auto s = std::make_unique<BevCalibSession>();
        for (const CalibCamera &c : l.cameras) s->camera_ids.push_back(cfg.slots[c.position].camera);
        s->session = std::make_unique<CalibSession>(l, lens_dir ? lens_dir : ".");
        return s.release();
    } catch (const std::exception &e) {
        fail(e.what());
        return nullptr;
    }
}

void bev_calib_close(BevCalibSession *s) { delete s; }

int32_t bev_calib_has_lens(BevCalibSession *s, int32_t cam)
{
    if (bad_cam(s, cam)) return 0;
    std::lock_guard<std::mutex> lock(s->mutex);
    return s->session->has_lens(cam);
}

int32_t bev_calib_set_lens(BevCalibSession *s, int32_t cam, const char *lens_dir, const char *lens)
{
    if (bad_cam(s, cam)) return 0;
    std::lock_guard<std::mutex> lock(s->mutex);
    return guarded([&] {
        s->session->set_lens(cam, lens_dir ? lens_dir : ".", lens ? lens : "");
        return 1;
    });
}

int32_t bev_calib_capture(BevCalibSession *s, int32_t cam, int32_t settle_frames)
{
    if (bad_cam(s, cam)) return 0;
    std::lock_guard<std::mutex> lock(s->mutex);
    return guarded([&] {
        const std::string &id = s->camera_ids[(size_t)cam];
        if (id.empty())
            return fail(std::string("no camera is assigned to ") +
                        bev_position_name(s->session->layout().cameras[(size_t)cam].position) +
                        "; assign one in Settings, Cameras");
        cv::Mat still;
        {
            StillCamera camera(id);
            still = camera.settled(std::max(1, (int)settle_frames));
        }
        s->session->set_image(cam, still);
        return 1;
    });
}

int32_t bev_calib_load_image(BevCalibSession *s, int32_t cam, const char *path)
{
    if (bad_cam(s, cam)) return 0;
    std::lock_guard<std::mutex> lock(s->mutex);
    cv::Mat img = cv::imread(path);
    if (img.empty()) return fail(std::string("cannot read ") + path);
    s->session->set_image(cam, img);
    return 1;
}

int32_t bev_calib_save_image(BevCalibSession *s, int32_t cam, const char *path)
{
    if (bad_cam(s, cam)) return 0;
    std::lock_guard<std::mutex> lock(s->mutex);
    const cv::Mat &img = s->session->image(cam);
    if (img.empty()) return fail("no image captured");
    return guarded([&] { return cv::imwrite(path, img) ? 1 : fail(std::string("cannot write ") + path); });
}

int32_t bev_calib_image_size(BevCalibSession *s, int32_t cam, int32_t *w, int32_t *h)
{
    if (bad_cam(s, cam)) return 0;
    std::lock_guard<std::mutex> lock(s->mutex);
    const cv::Mat &img = s->session->image(cam);
    if (img.empty()) return fail("no image captured");
    *w = img.cols;
    *h = img.rows;
    return 1;
}

int32_t bev_calib_detect(BevCalibSession *s, int32_t cam)
{
    if (bad_cam(s, cam)) return -1;
    std::lock_guard<std::mutex> lock(s->mutex);
    try {
        return s->session->detect(cam);
    } catch (const std::exception &e) {
        fail(e.what());
        return -1;
    }
}

int32_t bev_calib_point_count(BevCalibSession *s, int32_t cam)
{
    if (bad_cam(s, cam)) return 0;
    std::lock_guard<std::mutex> lock(s->mutex);
    return (int32_t)s->session->points(cam).size();
}

int32_t bev_calib_point(BevCalibSession *s, int32_t cam, int32_t index, BevCalibPoint *out)
{
    if (bad_cam(s, cam)) return 0;
    std::lock_guard<std::mutex> lock(s->mutex);
    const auto &pts = s->session->points(cam);
    if (index < 0 || index >= (int32_t)pts.size()) return fail("no such point");
    const CalibPoint &p = pts[(size_t)index];
    out->x = p.image.x;
    out->y = p.image.y;
    out->world_x = p.world.x;
    out->world_y = p.world.y;
    out->board = p.board;
    out->corner = p.corner;
    out->moved = p.moved;
    out->inlier = p.inlier;
    out->guessed = p.guessed;
    return 1;
}

int32_t bev_calib_move_point(BevCalibSession *s, int32_t cam, int32_t index, float x, float y)
{
    if (bad_cam(s, cam)) return 0;
    std::lock_guard<std::mutex> lock(s->mutex);
    if (index < 0 || index >= (int32_t)s->session->points(cam).size()) return fail("no such point");
    s->session->move_point(cam, index, {x, y});
    return 1;
}

int32_t bev_calib_solve(BevCalibSession *s, int32_t cam, BevCalibSolve *out)
{
    if (bad_cam(s, cam)) return 0;
    std::lock_guard<std::mutex> lock(s->mutex);
    return guarded([&] {
        const bool ok = s->session->solve(cam);
        const CalibSolve &r = s->session->result(cam);
        out->ok = ok;
        out->inliers = r.inliers;
        out->rms_px = r.rms_px;
        out->max_px = r.max_px;
        out->ground_rms_mm = r.ground_rms_mm;
        out->ground_max_mm = r.ground_max_mm;
        return ok ? 1 : fail("not enough corners to solve this camera");
    });
}

int32_t bev_calib_add_missing(BevCalibSession *s, int32_t cam)
{
    if (bad_cam(s, cam)) return -1;
    std::lock_guard<std::mutex> lock(s->mutex);
    const int n = s->session->add_missing(cam);
    if (n < 0) t_error = "needs at least 4 corners on this camera first";
    return n;
}

int32_t bev_calib_place_point(BevCalibSession *s, int32_t cam, int32_t board, int32_t corner, float x, float y)
{
    if (bad_cam(s, cam)) return -1;
    std::lock_guard<std::mutex> lock(s->mutex);
    try {
        return s->session->place(cam, board, corner, {x, y});
    } catch (const std::exception &e) {
        t_error = e.what();
        return -1;
    }
}

static bool bad_board(BevCalibSession *s, int32_t board)
{
    if (s && board >= 0 && board < (int32_t)s->session->layout().boards.size()) return false;
    t_error = "no such board in this layout";
    return true;
}

int32_t bev_calib_board_corner_count(BevCalibSession *s, int32_t board)
{
    if (bad_board(s, board)) return 0;
    return (int32_t)s->session->sheet_corners(board).size();
}

int32_t bev_calib_board_corner(BevCalibSession *s, int32_t board, int32_t corner, double *x, double *y)
{
    if (bad_board(s, board)) return 0;
    const auto &c = s->session->sheet_corners(board);
    if (corner < 0 || corner >= (int32_t)c.size()) return fail("no such corner");
    *x = c[(size_t)corner].x;
    *y = c[(size_t)corner].y;
    return 1;
}

int32_t bev_calib_board_reference(BevCalibSession *s, int32_t board, int32_t corner, int32_t width,
                                  const char *png_path, double *margin_m, double *px_per_m)
{
    if (bad_board(s, board)) return 0;
    std::lock_guard<std::mutex> lock(s->mutex);
    return guarded([&] {
        const cv::Mat img = s->session->board_reference(board, corner, width, *margin_m, *px_per_m);
        return cv::imwrite(png_path, img) ? 1 : fail(std::string("cannot write ") + png_path);
    });
}

int32_t bev_calib_seam_count(BevCalibSession *s)
{
    if (!s) return 0;
    std::lock_guard<std::mutex> lock(s->mutex);
    s->seams = s->session->seams();
    return (int32_t)s->seams.size();
}

int32_t bev_calib_seam(BevCalibSession *s, int32_t index, BevCalibSeam *out)
{
    if (!s) return 0;
    std::lock_guard<std::mutex> lock(s->mutex);
    if (index < 0 || index >= (int32_t)s->seams.size()) return fail("no such seam");
    const CalibSeam &m = s->seams[(size_t)index];
    out->cam_a = m.cam_a;
    out->cam_b = m.cam_b;
    out->shared = m.shared;
    out->median_mm = m.median_mm;
    out->max_mm = m.max_mm;
    return 1;
}

int32_t bev_calib_render_preview(BevCalibSession *s, double px_per_m, const char *path)
{
    if (!s) return fail("no session");
    std::lock_guard<std::mutex> lock(s->mutex);
    return guarded([&] {
        return cv::imwrite(path, s->session->render_preview(px_per_m)) ? 1
                                                                       : fail(std::string("cannot write ") + path);
    });
}

int32_t bev_calib_save_config(BevCalibSession *s, const char *config_path)
{
    if (!s) return fail("no session");
    std::lock_guard<std::mutex> lock(s->mutex);
    BevConfig cfg;
    if (!bev_config_load(config_path, cfg)) return fail(std::string("malformed ") + config_path);
    s->session->apply(cfg);
    return bev_config_save(config_path, cfg) ? 1 : fail(std::string("cannot write ") + config_path);
}

BevCalibIntrinsics *bev_intr_open(const char *camera_id, const char *dict, int32_t squares_x,
                                  int32_t squares_y, double square_len, double marker_len, int32_t legacy,
                                  int32_t fisheye)
{
    CalibBoard b;
    b.dict = dict;
    b.squares_x = squares_x;
    b.squares_y = squares_y;
    b.square_len = square_len;
    b.marker_len = marker_len;
    b.legacy = legacy != 0;
    try {
        auto h = std::make_unique<BevCalibIntrinsics>();
        h->calib = std::make_unique<IntrinsicsCalib>(b, fisheye != 0);
        h->camera = std::make_unique<StillCamera>(camera_id ? camera_id : "");
        return h.release();
    } catch (const std::exception &e) {
        fail(e.what());
        return nullptr;
    }
}

void bev_intr_close(BevCalibIntrinsics *h) { delete h; }

int32_t bev_intr_grab(BevCalibIntrinsics *h, const char *preview_path, int32_t preview_width,
                      BevIntrStatus *out)
{
    if (!h) return fail("no session");
    std::lock_guard<std::mutex> lock(h->mutex);
    return guarded([&] {
        cv::Mat frame = h->camera->grab();
        h->last = h->calib->detect(frame);
        h->last_size = frame.size();

        const double scale = (double)preview_width / frame.cols;
        cv::Mat small;
        cv::resize(frame, small, {}, scale, scale, cv::INTER_AREA);
        const int r = std::max(2, preview_width / 300);
        for (const IntrinsicsShot &shot : h->calib->shots())
            for (const cv::Point2f &p : shot.corners)
                cv::circle(small, p * scale, r, cv::Scalar(255, 160, 40), cv::FILLED);
        const cv::Scalar now = h->last.usable ? cv::Scalar(80, 220, 80) : cv::Scalar(60, 60, 230);
        for (const cv::Point2f &p : h->last.corners)
            cv::circle(small, p * scale, r * 2, now, 2, cv::LINE_AA);
        if (!cv::imwrite(preview_path, small)) return fail(std::string("cannot write ") + preview_path);

        out->corners = (int32_t)h->last.corners.size();
        out->usable = h->last.usable;
        out->views = h->calib->views();
        out->width = frame.cols;
        out->height = frame.rows;
        out->markers = h->last.markers;
        out->id_min = h->last.id_min;
        out->id_max = h->last.id_max;
        return 1;
    });
}

int32_t bev_intr_add(BevCalibIntrinsics *h)
{
    if (!h) return -1;
    std::lock_guard<std::mutex> lock(h->mutex);
    if (!h->calib->add(h->last, h->last_size)) {
        t_error = "the board isn't detected well enough in this frame";
        return -1;
    }
    h->last = IntrinsicsShot{};
    return h->calib->views();
}

int32_t bev_intr_calibrate(BevCalibIntrinsics *h, BevIntrResult *out)
{
    if (!h) return fail("no session");
    std::lock_guard<std::mutex> lock(h->mutex);
    return guarded([&] {
        h->result = h->calib->calibrate();
        const IntrinsicsResult &r = h->result;
        *out = BevIntrResult{r.ok, r.image_w, r.image_h, r.views, r.rms_px, r.worst_view_px,
                             r.fx, r.fy, r.cx, r.cy, r.k1, r.k2, r.p1, r.p2, r.k3, r.fisheye, r.k4};
        return r.ok ? 1 : fail("need at least 3 views");
    });
}

int32_t bev_intr_save(BevCalibIntrinsics *h, const char *lens_ini_path)
{
    if (!h) return fail("no session");
    std::lock_guard<std::mutex> lock(h->mutex);
    if (!h->result.ok) return fail("calibrate first");
    return IntrinsicsCalib::save_lens_ini(lens_ini_path, h->result) ? 1
                                                                   : fail(std::string("cannot write ") + lens_ini_path);
}

} // extern "C"
