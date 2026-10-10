#include "lens.h"

#include "bev_config.h"

#include <opencv2/calib3d.hpp>

#include <cmath>

Lens::Lens(const BevSlotConfig &sc, cv::Size frame)
    : valid_(true), fisheye_(sc.fisheye)
{
    const double sx = (double)frame.width / sc.lens_calib_w, sy = (double)frame.height / sc.lens_calib_h;
    K_ = cv::Matx33d(sc.fx * sx, 0, sc.cx * sx, 0, sc.fy * sy, sc.cy * sy, 0, 0, 1);
    if (fisheye_) dist_ = {sc.k1, sc.k2, sc.k3, sc.k4};
    else          dist_ = {sc.k1, sc.k2, sc.p1, sc.p2, sc.k3};
}

std::vector<cv::Point2f> Lens::undistort(const std::vector<cv::Point2f> &raw) const
{
    if (!valid_ || raw.empty()) return raw;
    std::vector<cv::Point2f> out;
    if (fisheye_) cv::fisheye::undistortPoints(raw, out, K_, dist_, cv::noArray(), K_);
    else          cv::undistortPoints(raw, out, K_, dist_, cv::noArray(), K_);
    return out;
}

cv::Point2d Lens::distort(cv::Point2d p) const
{
    if (!valid_) return p;
    const double fx = K_(0, 0), fy = K_(1, 1), cx = K_(0, 2), cy = K_(1, 2);
    const double x = (p.x - cx) / fx, y = (p.y - cy) / fy;
    const std::vector<double> &d = dist_;
    double xd, yd;
    if (fisheye_) {
        const double r = std::sqrt(x * x + y * y), th = std::atan(r), t2 = th * th;
        const double thd = th * (1 + t2 * (d[0] + t2 * (d[1] + t2 * (d[2] + t2 * d[3]))));
        const double k = r > 1e-8 ? thd / r : 1.0;
        xd = x * k;
        yd = y * k;
    } else {
        const double r2 = x * x + y * y;
        const double rad = 1 + d[0] * r2 + d[1] * r2 * r2 + d[4] * r2 * r2 * r2;
        xd = x * rad + 2 * d[2] * x * y + d[3] * (r2 + 2 * x * x);
        yd = y * rad + d[2] * (r2 + 2 * y * y) + 2 * d[3] * x * y;
    }
    return {xd * fx + cx, yd * fy + cy};
}

std::vector<bool> Lens::invertible(const std::vector<cv::Point2f> &raw,
                                   const std::vector<cv::Point2f> &und) const
{
    std::vector<bool> ok(raw.size(), true);
    if (!valid_) return ok;
    for (size_t i = 0; i < raw.size(); ++i) {
        const cv::Point2d u(und[i]);
        ok[i] = std::isfinite(u.x) && std::isfinite(u.y) && cv::norm(distort(u) - cv::Point2d(raw[i])) < 0.5;
    }
    return ok;
}
