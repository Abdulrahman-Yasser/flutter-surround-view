#pragma once

#include <opencv2/core.hpp>

#include <vector>

struct BevSlotConfig;

// One camera's lens at one frame size: the pinhole model with OpenCV's
// k1, k2, p1, p2, k3, or cv::fisheye with k1..k4. Undistorted pixels keep
// the same K, as the renderer expects. A default Lens is the identity.
class Lens {
public:
    Lens() = default;
    // sc must hold a loaded lens file; K is rescaled from its calib_w/h.
    Lens(const BevSlotConfig &sc, cv::Size frame);

    bool valid() const { return valid_; }
    bool fisheye() const { return fisheye_; }
    const cv::Matx33d &K() const { return K_; }

    std::vector<cv::Point2f> undistort(const std::vector<cv::Point2f> &raw) const;
    cv::Point2d distort(cv::Point2d undistorted) const;

    // False where the lens can't be inverted (past the fisheye's range), so
    // undistort() gave a point that doesn't map back.
    std::vector<bool> invertible(const std::vector<cv::Point2f> &raw,
                                 const std::vector<cv::Point2f> &und) const;

private:
    bool valid_ = false, fisheye_ = false;
    cv::Matx33d K_ = cv::Matx33d::eye();
    std::vector<double> dist_;
};
