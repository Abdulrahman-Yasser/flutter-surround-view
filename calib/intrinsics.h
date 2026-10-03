#pragma once

#include "calib_layout.h"

#include <opencv2/core.hpp>

#include <memory>
#include <string>
#include <vector>

class CharucoModel;

struct IntrinsicsShot {
    std::vector<cv::Point2f> corners;
    std::vector<int> ids;
    bool usable = false;     // enough corners, spread over more than one row and column
};

struct IntrinsicsResult {
    bool ok = false;
    int image_w = 0, image_h = 0;
    int views = 0;
    double rms_px = 0, worst_view_px = 0;
    double fx = 0, fy = 0, cx = 0, cy = 0;
    double k1 = 0, k2 = 0, p1 = 0, p2 = 0, k3 = 0;
};

// Lens calibration from many photos of one board held at varied poses,
// the in-app counterpart of scripts/calibrate_intrinsics.py.
class IntrinsicsCalib {
public:
    explicit IntrinsicsCalib(const CalibBoard &board, int min_corners = 6);
    ~IntrinsicsCalib();

    IntrinsicsShot detect(const cv::Mat &bgr) const;
    // Keeps a usable shot; all shots must share one image size.
    bool add(const IntrinsicsShot &shot, cv::Size size);
    int views() const { return (int)shots_.size(); }
    const std::vector<IntrinsicsShot> &shots() const { return shots_; }

    IntrinsicsResult calibrate() const;
    static bool save_lens_ini(const std::string &path, const IntrinsicsResult &r);

private:
    std::unique_ptr<CharucoModel> board_;
    int min_corners_;
    cv::Size size_;
    std::vector<IntrinsicsShot> shots_;
};
