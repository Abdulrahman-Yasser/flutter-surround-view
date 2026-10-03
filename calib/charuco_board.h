#pragma once

#include "calib_layout.h"

#include <opencv2/core.hpp>

#include <memory>
#include <vector>

struct ArucoMarkers {
    std::vector<std::vector<cv::Point2f>> corners;
    std::vector<int> ids;
};

// One printed ChArUco board, hiding the OpenCV API split: 4.7+ has it in
// objdetect, older releases in opencv_contrib's aruco module.
class CharucoModel {
public:
    explicit CharucoModel(const CalibBoard &cfg); // throws std::runtime_error
    ~CharucoModel();

    const CalibBoard &cfg() const { return cfg_; }
    int dict() const { return dict_; }

    // Corner positions in metres on the printed sheet: origin at its top-left,
    // +y down. Indexed by ChArUco corner id.
    const std::vector<cv::Point2d> &corners() const { return corners_; }

    static ArucoMarkers detect_markers(const cv::Mat &gray, int dict);
    void interpolate(const cv::Mat &gray, const ArucoMarkers &all,
                     std::vector<cv::Point2f> &corners, std::vector<int> &ids) const;

private:
    struct Impl;
    CalibBoard cfg_;
    int dict_ = 0;
    std::vector<cv::Point2d> corners_;
    std::unique_ptr<Impl> impl_;
};
