#include "calib_session.h"

#include "bev_config.h"
#include "bev_setup.h"
#include "charuco_board.h"

#include <opencv2/calib3d.hpp>
#include <opencv2/imgproc.hpp>

#include <algorithm>
#include <cmath>
#include <fstream>
#include <map>
#include <stdexcept>

struct CalibSession::Cam {
    cv::Mat image, gray;
    std::vector<CalibPoint> points;
    CalibSolve solve;
    bool has_lens = false;
    cv::Matx33d K;
    std::vector<double> dist;
    int lens_w = 0, lens_h = 0;
    double fx = 0, fy = 0, cx = 0, cy = 0;
};

CalibSession::CalibSession(const CalibLayout &layout, const std::string &lens_dir)
    : layout_(layout)
{
    for (const CalibBoard &cb : layout_.boards) {
        boards_.push_back(std::make_unique<CharucoModel>(cb));
        const double w = cb.squares_x * cb.square_len, h = cb.squares_y * cb.square_len;
        const double c = std::cos(cb.yaw_deg * CV_PI / 180), s = std::sin(cb.yaw_deg * CV_PI / 180);
        std::vector<cv::Point2d> world;
        for (const cv::Point2d &p : boards_.back()->corners()) {
            double u = p.x - w / 2, v = h / 2 - p.y;
            world.emplace_back(cb.x + u * c - v * s, cb.y + u * s + v * c);
        }
        world_.push_back(std::move(world));
    }

    cams_.resize(layout_.cameras.size());
    for (size_t i = 0; i < cams_.size(); ++i) {
        const std::string &lens = layout_.cameras[i].lens;
        if (lens.empty()) continue;
        std::string path = lens_calib_path(lens_dir, lens);
        if (!std::ifstream(path).good()) continue;
        BevSlotConfig sc;
        if (!lens_calib_load(path, sc))
            throw std::runtime_error("malformed lens file " + path);
        Cam &cam = cams_[i];
        cam.has_lens = true;
        cam.lens_w = sc.lens_calib_w;
        cam.lens_h = sc.lens_calib_h;
        cam.fx = sc.fx; cam.fy = sc.fy; cam.cx = sc.cx; cam.cy = sc.cy;
        cam.dist = {sc.k1, sc.k2, sc.p1, sc.p2, sc.k3};
    }
}

CalibSession::~CalibSession() = default;

void CalibSession::set_image(int cam, const cv::Mat &bgr)
{
    Cam &c = cams_.at(cam);
    c.image = bgr.clone();
    cv::cvtColor(bgr, c.gray, cv::COLOR_BGR2GRAY);
    c.points.clear();
    c.solve = CalibSolve{};
    if (c.has_lens) {
        // The lens file may have been fit at another resolution than this frame.
        double sx = (double)bgr.cols / c.lens_w, sy = (double)bgr.rows / c.lens_h;
        c.K = cv::Matx33d(c.fx * sx, 0, c.cx * sx, 0, c.fy * sy, c.cy * sy, 0, 0, 1);
    }
}

bool CalibSession::has_lens(int cam) const { return cams_.at(cam).has_lens; }
const cv::Mat &CalibSession::image(int cam) const { return cams_.at(cam).image; }
const std::vector<CalibPoint> &CalibSession::points(int cam) const { return cams_.at(cam).points; }
const CalibSolve &CalibSession::result(int cam) const { return cams_.at(cam).solve; }

int CalibSession::detect(int cam)
{
    Cam &c = cams_.at(cam);
    c.points.clear();
    c.solve = CalibSolve{};
    if (c.gray.empty()) return 0;

    std::map<int, ArucoMarkers> markers;
    for (const auto &b : boards_)
        if (!markers.count(b->dict())) markers[b->dict()] = CharucoModel::detect_markers(c.gray, b->dict());

    for (size_t bi = 0; bi < boards_.size(); ++bi) {
        std::vector<cv::Point2f> cc;
        std::vector<int> cid;
        boards_[bi]->interpolate(c.gray, markers[boards_[bi]->dict()], cc, cid);
        for (size_t i = 0; i < cid.size(); ++i) {
            CalibPoint p;
            p.board = (int)bi;
            p.corner = cid[i];
            p.image = cc[i];
            p.world = world_[bi][cid[i]];
            c.points.push_back(p);
        }
    }
    return (int)c.points.size();
}

void CalibSession::move_point(int cam, int idx, cv::Point2f image_px)
{
    CalibPoint &p = cams_.at(cam).points.at(idx);
    p.image = image_px;
    p.moved = true;
}

std::vector<cv::Point2f> CalibSession::undistorted(int cam, const std::vector<cv::Point2f> &raw) const
{
    const Cam &c = cams_.at(cam);
    if (!c.has_lens || raw.empty()) return raw;
    std::vector<cv::Point2f> out;
    cv::undistortPoints(raw, out, c.K, c.dist, cv::noArray(), c.K);
    return out;
}

static cv::Point2d transform(const cv::Matx33d &H, cv::Point2d p)
{
    cv::Vec3d r = H * cv::Vec3d(p.x, p.y, 1.0);
    return {r[0] / r[2], r[1] / r[2]};
}

bool CalibSession::solve(int cam)
{
    Cam &c = cams_.at(cam);
    c.solve = CalibSolve{};
    for (CalibPoint &p : c.points) p.inlier = false;
    if (c.points.size() < 4) return false;

    std::vector<cv::Point2f> raw, world;
    for (const CalibPoint &p : c.points) {
        raw.push_back(p.image);
        world.emplace_back((float)p.world.x, (float)p.world.y);
    }
    std::vector<cv::Point2f> und = undistorted(cam, raw);

    std::vector<unsigned char> mask;
    cv::Mat H = cv::findHomography(world, und, cv::RANSAC, 3.0, mask);
    if (H.empty()) return false;

    CalibSolve &s = c.solve;
    s.hb2i = cv::Matx33d(H) * (1.0 / H.at<double>(2, 2));
    const cv::Matx33d inv = s.hb2i.inv();
    double sq_px = 0, sq_mm = 0;
    for (size_t i = 0; i < c.points.size(); ++i) {
        if (!mask[i]) continue;
        c.points[i].inlier = true;
        double e_px = cv::norm(transform(s.hb2i, c.points[i].world) - cv::Point2d(und[i]));
        double e_mm = cv::norm(transform(inv, und[i]) - c.points[i].world) * 1000.0;
        sq_px += e_px * e_px;
        sq_mm += e_mm * e_mm;
        s.max_px = std::max(s.max_px, e_px);
        s.ground_max_mm = std::max(s.ground_max_mm, e_mm);
        ++s.inliers;
    }
    if (s.inliers < 4) {
        s = CalibSolve{};
        return false;
    }
    s.rms_px = std::sqrt(sq_px / s.inliers);
    s.ground_rms_mm = std::sqrt(sq_mm / s.inliers);
    s.ok = true;
    return true;
}

std::vector<CalibSeam> CalibSession::seams() const
{
    std::vector<CalibSeam> out;
    for (int a = 0; a < cameras(); ++a) {
        for (int b = a + 1; b < cameras(); ++b) {
            const Cam &ca = cams_[a], &cb = cams_[b];
            if (!ca.solve.ok || !cb.solve.ok) continue;

            std::map<std::pair<int, int>, cv::Point2f> in_a;
            for (const CalibPoint &p : ca.points)
                if (p.inlier) in_a[{p.board, p.corner}] = p.image;
            std::vector<cv::Point2f> ra, rb;
            for (const CalibPoint &p : cb.points) {
                if (!p.inlier) continue;
                auto it = in_a.find({p.board, p.corner});
                if (it == in_a.end()) continue;
                ra.push_back(it->second);
                rb.push_back(p.image);
            }
            if (ra.empty()) continue;

            std::vector<cv::Point2f> ua = undistorted(a, ra), ub = undistorted(b, rb);
            const cv::Matx33d ia = ca.solve.hb2i.inv(), ib = cb.solve.hb2i.inv();
            std::vector<double> err;
            for (size_t i = 0; i < ua.size(); ++i)
                err.push_back(cv::norm(transform(ia, ua[i]) - transform(ib, ub[i])) * 1000.0);
            std::sort(err.begin(), err.end());

            CalibSeam s;
            s.cam_a = a;
            s.cam_b = b;
            s.shared = (int)err.size();
            s.median_mm = err[err.size() / 2];
            s.max_mm = err.back();
            out.push_back(s);
        }
    }
    return out;
}

cv::Mat CalibSession::render_preview(double px_per_m) const
{
    double x0 = -layout_.car_width / 2, x1 = layout_.car_width / 2;
    double y0 = -layout_.car_length / 2, y1 = layout_.car_length / 2;
    for (const auto &board : world_) {
        for (const cv::Point2d &p : board) {
            x0 = std::min(x0, p.x); x1 = std::max(x1, p.x);
            y0 = std::min(y0, p.y); y1 = std::max(y1, p.y);
        }
    }
    const double margin = 0.5;
    x0 -= margin; x1 += margin; y0 -= margin; y1 += margin;
    const int W = (int)std::ceil((x1 - x0) * px_per_m), Hh = (int)std::ceil((y1 - y0) * px_per_m);
    auto to_canvas = [&](cv::Point2d w) {
        return cv::Point2f((float)((w.x - x0) * px_per_m), (float)((y1 - w.y) * px_per_m));
    };

    cv::Mat acc(Hh, W, CV_32FC3, cv::Scalar::all(0)), weight(Hh, W, CV_32F, cv::Scalar(0));
    for (int ci = 0; ci < cameras(); ++ci) {
        const Cam &c = cams_[ci];
        if (!c.solve.ok) continue;
        cv::Mat mapx(Hh, W, CV_32F), mapy(Hh, W, CV_32F), valid(Hh, W, CV_8U, cv::Scalar(0));
        const cv::Matx33d &H = c.solve.hb2i;
        const double fx = c.has_lens ? c.K(0, 0) : 1, fy = c.has_lens ? c.K(1, 1) : 1;
        const double cx = c.has_lens ? c.K(0, 2) : 0, cy = c.has_lens ? c.K(1, 2) : 0;
        for (int y = 0; y < Hh; ++y) {
            for (int x = 0; x < W; ++x) {
                cv::Vec3d r = H * cv::Vec3d(x0 + (x + 0.5) / px_per_m, y1 - (y + 0.5) / px_per_m, 1.0);
                if (r[2] <= 0) {
                    mapx.at<float>(y, x) = mapy.at<float>(y, x) = -1;
                    continue;
                }
                double u = r[0] / r[2], v = r[1] / r[2];
                if (c.has_lens) {
                    double xn = (u - cx) / fx, yn = (v - cy) / fy, r2 = xn * xn + yn * yn;
                    double k1 = c.dist[0], k2 = c.dist[1], p1 = c.dist[2], p2 = c.dist[3], k3 = c.dist[4];
                    double rad = 1 + k1 * r2 + k2 * r2 * r2 + k3 * r2 * r2 * r2;
                    double xd = xn * rad + 2 * p1 * xn * yn + p2 * (r2 + 2 * xn * xn);
                    double yd = yn * rad + p1 * (r2 + 2 * yn * yn) + 2 * p2 * xn * yn;
                    u = xd * fx + cx;
                    v = yd * fy + cy;
                }
                mapx.at<float>(y, x) = (float)u;
                mapy.at<float>(y, x) = (float)v;
                if (u >= 0 && v >= 0 && u < c.image.cols - 1 && v < c.image.rows - 1)
                    valid.at<unsigned char>(y, x) = 1;
            }
        }
        cv::Mat warped, warped_f;
        cv::remap(c.image, warped, mapx, mapy, cv::INTER_LINEAR, cv::BORDER_CONSTANT);
        warped.convertTo(warped_f, CV_32FC3);
        cv::add(acc, warped_f, acc, valid);
        cv::add(weight, cv::Scalar(1), weight, valid);
    }

    cv::Mat w3, out;
    cv::Mat wsafe = cv::max(weight, 1.0f);
    cv::merge(std::vector<cv::Mat>{wsafe, wsafe, wsafe}, w3);
    cv::divide(acc, w3, acc);
    acc.convertTo(out, CV_8UC3);

    cv::Point2f car0 = to_canvas({-layout_.car_width / 2, layout_.car_length / 2});
    cv::Point2f car1 = to_canvas({layout_.car_width / 2, -layout_.car_length / 2});
    cv::rectangle(out, car0, car1, cv::Scalar(200, 200, 200), 2);
    for (const auto &board : world_)
        for (const cv::Point2d &p : board)
            cv::circle(out, to_canvas(p), 3, cv::Scalar(0, 255, 0), 1, cv::LINE_AA);
    return out;
}

void CalibSession::apply(BevConfig &cfg) const
{
    for (int i = 0; i < cameras(); ++i) {
        const Cam &c = cams_[i];
        if (!c.solve.ok) continue;
        const CalibCamera &cc = layout_.cameras[i];
        BevSlotConfig &s = cfg.slots[cc.slot];
        for (int col = 0; col < 3; ++col)
            for (int row = 0; row < 3; ++row)
                s.hb2i.at(row, col) = c.solve.hb2i(row, col);
        s.has_hb2i = true;
        s.hb2i_w = c.image.cols;
        s.hb2i_h = c.image.rows;
        s.facing_deg = cc.facing_deg;
        s.lens_model = cc.lens;
    }
    cfg.car_width = layout_.car_width;
    cfg.car_length = layout_.car_length;
    cfg.car_x = 0.0;
    cfg.car_y = 0.0;
}
