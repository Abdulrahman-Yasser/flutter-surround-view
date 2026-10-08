#include "intrinsics.h"

#include "charuco_board.h"

#include <opencv2/calib3d.hpp>
#include <opencv2/imgproc.hpp>

#include <cmath>
#include <fstream>
#include <set>

IntrinsicsCalib::IntrinsicsCalib(const CalibBoard &board, bool fisheye, int min_corners)
    : board_(std::make_unique<CharucoModel>(board)), fisheye_(fisheye), min_corners_(min_corners)
{
}

IntrinsicsCalib::~IntrinsicsCalib() = default;

IntrinsicsShot IntrinsicsCalib::detect(const cv::Mat &bgr) const
{
    IntrinsicsShot shot;
    cv::Mat gray;
    cv::cvtColor(bgr, gray, cv::COLOR_BGR2GRAY);
    board_->interpolate(gray, CharucoModel::detect_markers(gray, board_->dict()), shot.corners, shot.ids);
    if ((int)shot.ids.size() < min_corners_) return shot;

    // calibrateCamera's initial guess asserts on a view whose corners all sit
    // on one board row or column, so such a view is never usable.
    std::set<long> xs, ys;
    for (int id : shot.ids) {
        const cv::Point2d &p = board_->corners()[id];
        xs.insert(std::lround(p.x * 1e6));
        ys.insert(std::lround(p.y * 1e6));
    }
    shot.usable = xs.size() >= 2 && ys.size() >= 2;
    return shot;
}

bool IntrinsicsCalib::add(const IntrinsicsShot &shot, cv::Size size)
{
    if (!shot.usable) return false;
    if (shots_.empty()) size_ = size;
    else if (size != size_) return false;
    shots_.push_back(shot);
    return true;
}

IntrinsicsResult IntrinsicsCalib::calibrate() const
{
    IntrinsicsResult r;
    if (shots_.size() < 3) return r;

    std::vector<std::vector<cv::Point3f>> obj;
    std::vector<std::vector<cv::Point2f>> img;
    for (const IntrinsicsShot &s : shots_) {
        std::vector<cv::Point3f> o;
        for (int id : s.ids) {
            const cv::Point2d &p = board_->corners()[id];
            o.emplace_back((float)p.x, (float)p.y, 0.f);
        }
        obj.push_back(std::move(o));
        img.push_back(s.corners);
    }

    cv::Mat K, dist;
    std::vector<cv::Mat> rvecs, tvecs;
    if (fisheye_) {
        cv::Matx33d Kf;
        cv::Vec4d Df;
        cv::fisheye::calibrate(obj, img, size_, Kf, Df, rvecs, tvecs,
                               cv::fisheye::CALIB_RECOMPUTE_EXTRINSIC | cv::fisheye::CALIB_FIX_SKEW,
                               cv::TermCriteria(cv::TermCriteria::COUNT | cv::TermCriteria::EPS, 100, 1e-9));
        K = cv::Mat(Kf);
        dist = cv::Mat(Df);
    } else {
        cv::calibrateCamera(obj, img, size_, K, dist, rvecs, tvecs);
    }

    double sq = 0;
    size_t n = 0;
    for (size_t i = 0; i < obj.size(); ++i) {
        std::vector<cv::Point2f> proj;
        if (fisheye_) cv::fisheye::projectPoints(obj[i], proj, rvecs[i], tvecs[i], K, dist);
        else          cv::projectPoints(obj[i], rvecs[i], tvecs[i], K, dist, proj);
        double view_sq = 0;
        for (size_t j = 0; j < proj.size(); ++j) {
            cv::Point2f d = img[i][j] - proj[j];
            view_sq += d.dot(d);
        }
        r.worst_view_px = std::max(r.worst_view_px, std::sqrt(view_sq / proj.size()));
        sq += view_sq;
        n += proj.size();
    }

    r.ok = true;
    r.fisheye = fisheye_;
    r.image_w = size_.width;
    r.image_h = size_.height;
    r.views = (int)shots_.size();
    r.rms_px = std::sqrt(sq / n);
    r.fx = K.at<double>(0, 0);
    r.fy = K.at<double>(1, 1);
    r.cx = K.at<double>(0, 2);
    r.cy = K.at<double>(1, 2);
    const double *d = dist.ptr<double>();
    if (fisheye_) {
        r.k1 = d[0]; r.k2 = d[1]; r.k3 = d[2]; r.k4 = d[3];
    } else {
        r.k1 = d[0]; r.k2 = d[1]; r.p1 = d[2]; r.p2 = d[3]; r.k3 = d[4];
    }
    return r;
}

bool IntrinsicsCalib::save_lens_ini(const std::string &path, const IntrinsicsResult &r)
{
    std::ofstream f(path, std::ios::trunc);
    if (!f) return false;
    f.precision(7);
    f << "# lens intrinsics/distortion, written by the calibration screen\n"
      << "# looked up at runtime as <lens_dir>/<lens_model>-lens.ini\n\n"
      << "model = " << (r.fisheye ? "fisheye" : "pinhole") << "\n"
      << "fx = " << r.fx << "\nfy = " << r.fy << "\ncx = " << r.cx << "\ncy = " << r.cy << "\n"
      << "k1 = " << r.k1 << "\nk2 = " << r.k2 << "\nk3 = " << r.k3 << "\n";
    if (r.fisheye) f << "k4 = " << r.k4 << "\n";
    else           f << "p1 = " << r.p1 << "\np2 = " << r.p2 << "\n";
    f << "calib_w = " << r.image_w << "\ncalib_h = " << r.image_h << "\n";
    return (bool)f;
}
