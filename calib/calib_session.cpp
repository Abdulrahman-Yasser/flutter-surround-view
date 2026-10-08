#include "calib_session.h"

#include "bev_config.h"
#include "bev_setup.h"
#include "charuco_board.h"
#include "lens.h"

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
    BevSlotConfig lens_cfg;
    Lens lens;
};

// Printed-sheet metres (origin top-left, +y down) to the car frame.
static cv::Point2d sheet_to_world(const CalibBoard &cb, cv::Point2d p)
{
    const double w = cb.squares_x * cb.square_len, h = cb.squares_y * cb.square_len;
    const double c = std::cos(cb.yaw_deg * CV_PI / 180), s = std::sin(cb.yaw_deg * CV_PI / 180);
    const double u = p.x - w / 2, v = h / 2 - p.y;
    return {cb.x + u * c - v * s, cb.y + u * s + v * c};
}

static std::vector<cv::Point2d> square_corners(double side)
{
    return {{0, 0}, {side, 0}, {side, side}, {0, side}};
}

CalibSession::CalibSession(const CalibLayout &layout, const std::string &lens_dir)
    : layout_(layout)
{
    for (const CalibBoard &cb : layout_.boards) {
        boards_.push_back(cb.square ? nullptr : std::make_unique<CharucoModel>(cb));
        std::vector<cv::Point2d> world;
        for (const cv::Point2d &p : cb.square ? square_corners(cb.square_len) : boards_.back()->corners())
            world.push_back(sheet_to_world(cb, p));
        world_.push_back(std::move(world));
    }

    cams_.resize(layout_.cameras.size());
    for (int i = 0; i < cameras(); ++i) set_lens(i, lens_dir, layout_.cameras[i].lens);
}

CalibSession::~CalibSession() = default;

void CalibSession::set_lens(int cam, const std::string &lens_dir, const std::string &lens)
{
    Cam &c = cams_.at(cam);
    BevSlotConfig cfg;
    const std::string path = lens_calib_path(lens_dir, lens);
    const bool found = !lens.empty() && std::ifstream(path).good();
    if (found && !lens_calib_load(path, cfg)) throw std::runtime_error("malformed lens file " + path);
    layout_.cameras[cam].lens = lens;
    c.has_lens = found;
    c.lens_cfg = cfg;
    c.lens = found && !c.image.empty() ? Lens(cfg, c.image.size()) : Lens();
    c.solve = CalibSolve{};
    for (CalibPoint &p : c.points) p.inlier = false;
}

void CalibSession::set_image(int cam, const cv::Mat &bgr)
{
    Cam &c = cams_.at(cam);
    c.image = bgr.clone();
    cv::cvtColor(bgr, c.gray, cv::COLOR_BGR2GRAY);
    c.points.clear();
    c.solve = CalibSolve{};
    if (c.has_lens) c.lens = Lens(c.lens_cfg, bgr.size());
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
        if (b && !markers.count(b->dict())) markers[b->dict()] = CharucoModel::detect_markers(c.gray, b->dict());

    auto add_charuco = [&](int bi, const std::vector<cv::Point2f> &cc, const std::vector<int> &cid) {
        for (size_t i = 0; i < cid.size(); ++i) {
            CalibPoint p;
            p.board = bi;
            p.corner = cid[i];
            p.image = cc[i];
            p.world = world_[bi][cid[i]];
            c.points.push_back(p);
        }
    };
    // Squares, and ChArUco boards seen too obliquely or too far out in a
    // fisheye to decode, are looked for again in a top view of the ground
    // where the fit so far predicts them.
    std::map<int, std::vector<cv::Point2f>> missed;
    for (size_t bi = 0; bi < boards_.size(); ++bi) {
        if (!boards_[bi]) {
            missed[(int)bi];
            continue;
        }
        std::vector<cv::Point2f> cc;
        std::vector<int> cid;
        boards_[bi]->interpolate(c.gray, markers[boards_[bi]->dict()], cc, cid);
        add_charuco((int)bi, cc, cid);
        if ((int)cid.size() < layout_.boards[bi].corners() / 2) missed[(int)bi];
    }

    auto add_square = [&](int bi, const std::vector<cv::Point2f> &corners, bool found) {
        for (int k = 0; k < 4; ++k) {
            CalibPoint p;
            p.board = bi;
            p.corner = k;
            p.image = corners[k];
            p.world = world_[bi][k];
            p.guessed = !found;
            c.points.push_back(p);
        }
    };
    // Each board found refines the fit, which can bring a missed one within
    // reach, so retry the misses until a pass finds nothing new.
    for (bool progress = true; progress && !missed.empty();) {
        progress = false;
        cv::Matx33d H;
        std::vector<bool> in;
        if (!fit(cam, H, in)) break;
        for (auto it = missed.begin(); it != missed.end();) {
            const int bi = it->first;
            if (boards_[bi]) {
                std::vector<cv::Point2f> cc;
                std::vector<int> cid;
                const size_t had = std::count_if(c.points.begin(), c.points.end(),
                                                 [&](const CalibPoint &p) { return p.board == bi; });
                if (find_charuco(cam, bi, H, cc, cid) && cid.size() > had) {
                    c.points.erase(std::remove_if(c.points.begin(), c.points.end(),
                                                  [&](const CalibPoint &p) { return p.board == bi; }),
                                   c.points.end());
                    add_charuco(bi, cc, cid);
                    progress = true;
                }
                it = missed.erase(it);
                continue;
            }
            bool found = false;
            if (!find_square(cam, it->first, H, it->second, found)) {
                it = missed.erase(it);
            } else if (found) {
                add_square(it->first, it->second, true);
                it = missed.erase(it);
                progress = true;
            } else {
                ++it;
            }
        }
    }
    for (const auto &[bi, corners] : missed)
        if (!boards_[bi] && !corners.empty()) add_square(bi, corners, false);
    return (int)c.points.size();
}

void CalibSession::move_point(int cam, int idx, cv::Point2f image_px)
{
    CalibPoint &p = cams_.at(cam).points.at(idx);
    p.image = image_px;
    p.moved = true;
    p.guessed = false;
}

static cv::Point2d transform(const cv::Matx33d &H, cv::Point2d p)
{
    cv::Vec3d r = H * cv::Vec3d(p.x, p.y, 1.0);
    return {r[0] / r[2], r[1] / r[2]};
}

// World point to raw pixel through H and the lens; false behind the camera.
static bool project(const Lens &lens, const cv::Matx33d &H, cv::Point2d w, cv::Point2d &raw)
{
    cv::Vec3d r = H * cv::Vec3d(w.x, w.y, 1.0);
    if (r[2] <= 0) return false;
    raw = lens.distort({r[0] / r[2], r[1] / r[2]});
    return true;
}

// findHomography's sign is arbitrary. The renderer and project() need the
// third row positive for points in front of the camera, which dividing by
// H(2,2) only gets right when the car-frame origin is in front of it too.
static void orient(cv::Matx33d &H, const std::vector<cv::Point2d> &world)
{
    double z = 0;
    for (const cv::Point2d &w : world) z += (H * cv::Vec3d(w.x, w.y, 1.0))[2];
    H *= (z < 0 ? -1.0 : 1.0) / cv::norm(H);
}

// Levenberg-Marquardt on the raw-pixel reprojection error, so points far out
// in a fisheye count as much as they are measured, not as much as
// undistortion stretches them.
static void refine(cv::Matx33d &H, const std::vector<cv::Point2d> &world,
                   const std::vector<cv::Point2d> &raw, const Lens &lens)
{
    const size_t n = world.size();
    // Condition the parameters: centre and scale the world points, and work
    // on undistorted pixels in focal-length units.
    cv::Point2d mean(0, 0);
    for (const cv::Point2d &w : world) mean += w;
    mean *= 1.0 / n;
    double spread = 0;
    for (const cv::Point2d &w : world) spread += cv::norm(w - mean);
    spread = std::max(spread / n, 1e-6);
    const cv::Matx33d Tw(1 / spread, 0, -mean.x / spread, 0, 1 / spread, -mean.y / spread, 0, 0, 1);
    const cv::Matx33d &K = lens.K();
    const cv::Matx33d Ti = K.inv();
    cv::Matx33d A = Ti * H * Tw.inv();
    A *= 1.0 / cv::norm(A);

    int fixed = 0;
    for (int k = 1; k < 9; ++k)
        if (std::abs(A.val[k]) > std::abs(A.val[fixed])) fixed = k;

    auto residuals = [&](const cv::Matx33d &a, cv::Mat &r) {
        const cv::Matx33d h = K * a * Tw;
        r.create((int)(2 * n), 1, CV_64F);
        for (size_t i = 0; i < n; ++i) {
            cv::Point2d p;
            if (!project(lens, h, world[i], p)) p = raw[i] + cv::Point2d(1e3, 1e3);
            r.at<double>((int)(2 * i)) = p.x - raw[i].x;
            r.at<double>((int)(2 * i + 1)) = p.y - raw[i].y;
        }
    };

    cv::Mat r;
    residuals(A, r);
    double cost = r.dot(r), lambda = 1e-3;
    bool converged = false;
    for (int it = 0; it < 30 && !converged; ++it) {
        cv::Mat J((int)(2 * n), 8, CV_64F);
        for (int k = 0, col = 0; k < 9; ++k) {
            if (k == fixed) continue;
            const double eps = 1e-6;
            cv::Matx33d ap = A, am = A;
            ap.val[k] += eps;
            am.val[k] -= eps;
            cv::Mat rp, rm;
            residuals(ap, rp);
            residuals(am, rm);
            J.col(col++) = (rp - rm) / (2 * eps);
        }
        const cv::Mat JtJ = J.t() * J, Jtr = J.t() * r;
        bool improved = false;
        for (int tries = 0; tries < 10 && !improved; ++tries) {
            cv::Mat damped = JtJ.clone();
            for (int d = 0; d < 8; ++d) damped.at<double>(d, d) *= 1 + lambda;
            cv::Mat step;
            if (!cv::solve(damped, -Jtr, step, cv::DECOMP_CHOLESKY)) {
                lambda *= 10;
                continue;
            }
            cv::Matx33d trial = A;
            for (int k = 0, row = 0; k < 9; ++k)
                if (k != fixed) trial.val[k] += step.at<double>(row++);
            cv::Mat rt;
            residuals(trial, rt);
            const double c = rt.dot(rt);
            if (c < cost) {
                converged = cost - c < 1e-10 * cost;
                A = trial;
                r = rt;
                cost = c;
                lambda = std::max(lambda / 10, 1e-9);
                improved = true;
            } else {
                lambda *= 10;
            }
        }
        if (!improved) break;
    }
    H = K * A * Tw;
}

bool CalibSession::fit(int cam, cv::Matx33d &H, std::vector<bool> &inlier) const
{
    const Cam &c = cams_.at(cam);
    inlier.assign(c.points.size(), false);

    std::vector<int> idx;
    std::vector<cv::Point2f> raw;
    for (size_t i = 0; i < c.points.size(); ++i) {
        if (c.points[i].guessed) continue;
        idx.push_back((int)i);
        raw.push_back(c.points[i].image);
    }
    if (idx.size() < 4) return false;
    const std::vector<cv::Point2f> und = c.lens.undistort(raw);
    const std::vector<bool> usable = c.lens.invertible(raw, und);

    std::vector<cv::Point2f> fw, fu;
    std::vector<cv::Point2d> world;
    for (size_t i = 0; i < idx.size(); ++i) {
        world.push_back(c.points[idx[i]].world);
        if (!usable[i]) continue;
        fw.emplace_back((float)world.back().x, (float)world.back().y);
        fu.push_back(und[i]);
    }
    if (fw.size() < 4) return false;
    cv::Mat H0 = cv::findHomography(fw, fu, cv::RANSAC, 8.0);
    if (H0.empty()) return false;
    H = cv::Matx33d(H0);
    orient(H, world);

    // Inliers by raw-pixel error, tightening as the refinement settles.
    std::vector<bool> in(idx.size());
    for (double thr : {10.0, 5.0, 3.0, 3.0}) {
        std::vector<cv::Point2d> sw, sr;
        for (size_t i = 0; i < idx.size(); ++i) {
            cv::Point2d p;
            in[i] = project(c.lens, H, world[i], p) && cv::norm(p - cv::Point2d(raw[i])) < thr;
            if (!in[i]) continue;
            sw.push_back(world[i]);
            sr.emplace_back(raw[i]);
        }
        if (sw.size() < 4) return false;
        refine(H, sw, sr, c.lens);
        orient(H, sw);
    }
    int count = 0;
    for (size_t i = 0; i < idx.size(); ++i) {
        cv::Point2d p;
        inlier[idx[i]] = project(c.lens, H, world[i], p) && cv::norm(p - cv::Point2d(raw[i])) < 3.0;
        count += inlier[idx[i]];
    }
    return count >= 4;
}

// Resamples the ground over a board's sheet rectangle, origin at sheet
// (x0, y0), into a top view where the board is upright and undistorted
// whatever the lens and viewing angle. Patch pixel q sits at sheet
// (x0 + (q.x + 0.5) * m_per_px, y0 + (q.y + 0.5) * m_per_px).
template <typename ToRaw>
static cv::Mat top_view(const cv::Mat &gray, ToRaw to_raw, double x0, double y0, double m_per_px,
                        int w, int h)
{
    cv::Mat mapx(h, w, CV_32F), mapy(h, w, CV_32F);
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            cv::Point2d p;
            if (!to_raw(cv::Point2d(x0 + (x + 0.5) * m_per_px, y0 + (y + 0.5) * m_per_px), p)) p = {-1, -1};
            mapx.at<float>(y, x) = (float)p.x;
            mapy.at<float>(y, x) = (float)p.y;
        }
    }
    cv::Mat patch;
    cv::remap(gray, patch, mapx, mapy, cv::INTER_LINEAR, cv::BORDER_CONSTANT, cv::Scalar(255));
    return patch;
}

bool CalibSession::find_charuco(int cam, int board, const cv::Matx33d &H,
                                std::vector<cv::Point2f> &corners, std::vector<int> &ids) const
{
    const Cam &c = cams_.at(cam);
    const CalibBoard &b = layout_.boards[board];
    auto to_raw = [&](cv::Point2d sheet, cv::Point2d &raw) {
        return project(c.lens, H, sheet_to_world(b, sheet), raw);
    };
    const double w = b.squares_x * b.square_len, h = b.squares_y * b.square_len;
    cv::Point2d centre;
    if (!to_raw({w / 2, h / 2}, centre) || !cv::Rect2d(0, 0, c.gray.cols, c.gray.rows).contains(centre))
        return false;

    // About 80 px a square: plenty for the markers to decode, and no detail
    // the camera didn't resolve is lost by going larger.
    const double m_per_px = b.square_len / 80, pad = b.square_len;
    const cv::Mat patch = top_view(c.gray, to_raw, -pad, -pad, m_per_px,
                                   (int)std::ceil((w + 2 * pad) / m_per_px),
                                   (int)std::ceil((h + 2 * pad) / m_per_px));
    std::vector<cv::Point2f> cc;
    boards_[board]->interpolate(patch, CharucoModel::detect_markers(patch, boards_[board]->dict()), cc, ids);
    corners.clear();
    for (const cv::Point2f &q : cc) {
        cv::Point2d p;
        if (!to_raw({-pad + (q.x + 0.5) * m_per_px, -pad + (q.y + 0.5) * m_per_px}, p)) return false;
        corners.emplace_back(p);
    }
    return ids.size() >= 4;
}

bool CalibSession::find_square(int cam, int board, const cv::Matx33d &H,
                               std::vector<cv::Point2f> &corners, bool &found) const
{
    const Cam &c = cams_.at(cam);
    const CalibBoard &b = layout_.boards[board];
    const double side = b.square_len;
    auto to_raw = [&](cv::Point2d sheet, cv::Point2d &raw) {
        return project(c.lens, H, sheet_to_world(b, sheet), raw);
    };

    std::vector<cv::Point2d> pred(4);
    const std::vector<cv::Point2d> sheet = square_corners(side);
    const cv::Rect2d frame(2, 2, c.gray.cols - 4, c.gray.rows - 4);
    double L = 0;
    for (int k = 0; k < 4; ++k)
        if (!to_raw(sheet[k], pred[k]) || !frame.contains(pred[k])) return false;
    for (int k = 0; k < 4; ++k) L += cv::norm(pred[k] - pred[(k + 1) % 4]) / 4;
    if (L < 12) return false;

    corners.assign(pred.begin(), pred.end());
    found = false;

    // A top view twice the square's size, the square in its middle half.
    const int N = std::clamp((int)(2 * L), 64, 600);
    const double m_per_px = 2 * side / N;
    auto patch_to_sheet = [&](cv::Point2d q) {
        return cv::Point2d(-side / 2 + (q.x + 0.5) * m_per_px, -side / 2 + (q.y + 0.5) * m_per_px);
    };
    const cv::Mat patch = top_view(c.gray, to_raw, -side / 2, -side / 2, m_per_px, N, N);
    cv::Mat smooth, bin;
    cv::GaussianBlur(patch, smooth, {5, 5}, 0);
    cv::threshold(smooth, bin, 0, 255, cv::THRESH_BINARY_INV | cv::THRESH_OTSU);
    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(bin, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);

    const double s_px = N / 2.0;
    const cv::Point2d centre((N - 1) / 2.0, (N - 1) / 2.0);
    std::vector<cv::Point> best;
    double best_d = s_px / 2;
    for (const auto &contour : contours) {
        const double area = cv::contourArea(contour);
        if (area < 0.4 * s_px * s_px || area > 2.0 * s_px * s_px) continue;
        std::vector<cv::Point> quad;
        cv::approxPolyDP(contour, quad, 0.04 * cv::arcLength(contour, true), true);
        if (quad.size() != 4 || !cv::isContourConvex(quad)) continue;
        const cv::Moments m = cv::moments(quad);
        const double d = cv::norm(cv::Point2d(m.m10 / m.m00, m.m01 / m.m00) - centre);
        if (d < best_d) {
            best_d = d;
            best = quad;
        }
    }
    if (best.empty()) return true;

    std::vector<cv::Point2f> q(4);
    std::vector<bool> taken(4, false);
    for (int k = 0; k < 4; ++k) {
        const cv::Point2d expect(N / 4.0 - 0.5 + sheet[k].x / m_per_px, N / 4.0 - 0.5 + sheet[k].y / m_per_px);
        int pick = -1;
        double pick_d = 0.4 * s_px;
        for (int j = 0; j < 4; ++j) {
            const double d = cv::norm(cv::Point2d(best[j]) - expect);
            if (!taken[j] && d < pick_d) {
                pick = j;
                pick_d = d;
            }
        }
        if (pick < 0) return true;
        taken[pick] = true;
        q[k] = best[pick];
    }
    const int win = std::max(2, (int)(s_px / 12));
    cv::cornerSubPix(patch, q, {win, win}, {-1, -1},
                     cv::TermCriteria(cv::TermCriteria::EPS | cv::TermCriteria::COUNT, 30, 0.01));
    for (int k = 0; k < 4; ++k) {
        cv::Point2d p;
        if (!to_raw(patch_to_sheet(q[k]), p)) return true;
        corners[k] = p;
    }
    found = true;
    return true;
}

bool CalibSession::solve(int cam)
{
    Cam &c = cams_.at(cam);
    c.solve = CalibSolve{};
    for (CalibPoint &p : c.points) p.inlier = false;

    cv::Matx33d H;
    std::vector<bool> in;
    if (!fit(cam, H, in)) return false;

    std::vector<cv::Point2f> raw;
    for (const CalibPoint &p : c.points) raw.push_back(p.image);
    const std::vector<cv::Point2f> und = c.lens.undistort(raw);
    const std::vector<bool> usable = c.lens.invertible(raw, und);

    CalibSolve &s = c.solve;
    s.hb2i = H;
    const cv::Matx33d inv = s.hb2i.inv();
    double sq_px = 0, sq_mm = 0;
    int ground = 0;
    for (size_t i = 0; i < c.points.size(); ++i) {
        if (!in[i]) continue;
        c.points[i].inlier = true;
        cv::Point2d p;
        project(c.lens, H, c.points[i].world, p);
        const double e_px = cv::norm(p - cv::Point2d(raw[i]));
        sq_px += e_px * e_px;
        s.max_px = std::max(s.max_px, e_px);
        ++s.inliers;
        if (!usable[i]) continue;
        const double e_mm = cv::norm(transform(inv, und[i]) - c.points[i].world) * 1000.0;
        sq_mm += e_mm * e_mm;
        s.ground_max_mm = std::max(s.ground_max_mm, e_mm);
        ++ground;
    }
    s.rms_px = std::sqrt(sq_px / s.inliers);
    s.ground_rms_mm = ground ? std::sqrt(sq_mm / ground) : 0;
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

            const std::vector<cv::Point2f> ua = ca.lens.undistort(ra), ub = cb.lens.undistort(rb);
            const std::vector<bool> oa = ca.lens.invertible(ra, ua), ob = cb.lens.invertible(rb, ub);
            const cv::Matx33d ia = ca.solve.hb2i.inv(), ib = cb.solve.hb2i.inv();
            std::vector<double> err;
            for (size_t i = 0; i < ua.size(); ++i)
                if (oa[i] && ob[i])
                    err.push_back(cv::norm(transform(ia, ua[i]) - transform(ib, ub[i])) * 1000.0);
            if (err.empty()) continue;
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
        for (int y = 0; y < Hh; ++y) {
            for (int x = 0; x < W; ++x) {
                cv::Point2d p;
                if (!project(c.lens, c.solve.hb2i, {x0 + (x + 0.5) / px_per_m, y1 - (y + 0.5) / px_per_m}, p)) {
                    mapx.at<float>(y, x) = mapy.at<float>(y, x) = -1;
                    continue;
                }
                const double u = p.x, v = p.y;
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
        BevSlotConfig &s = cfg.slots[cc.position];
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
