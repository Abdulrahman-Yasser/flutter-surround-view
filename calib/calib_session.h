#pragma once

#include "calib_layout.h"

#include <opencv2/core.hpp>

#include <memory>
#include <string>
#include <vector>

struct BevConfig;
class CharucoModel;

struct CalibPoint {
    int         board = 0;       // index into CalibLayout::boards
    int         corner = 0;      // ChArUco corner id within that board
    cv::Point2f image;           // raw (distorted) frame pixel, what the user drags
    cv::Point2d world;           // car frame, metres
    bool        moved = false;   // edited by hand after detection
    bool        inlier = false;  // survived the last solve's RANSAC
};

struct CalibSolve {
    bool        ok = false;
    cv::Matx33d hb2i;            // car metres -> undistorted pixels at the image's own size
    int         inliers = 0;
    double      rms_px = 0, max_px = 0;            // reprojection over inliers
    double      ground_rms_mm = 0, ground_max_mm = 0;
};

struct CalibSeam {
    int    cam_a = 0, cam_b = 0; // indices into CalibLayout::cameras
    int    shared = 0;           // corners that are inliers in both cameras
    double median_mm = 0, max_mm = 0;
};

// One calibration run over a layout. Cameras are addressed by their index in
// CalibLayout::cameras, not by slot. The constructor throws
// std::runtime_error on a layout OpenCV can't build or a malformed lens file;
// a camera whose lens file doesn't exist yet is solved without undistortion.
class CalibSession {
public:
    CalibSession(const CalibLayout &layout, const std::string &lens_dir);
    ~CalibSession();

    const CalibLayout &layout() const { return layout_; }
    int cameras() const { return (int)layout_.cameras.size(); }

    bool has_lens(int cam) const;

    void set_image(int cam, const cv::Mat &bgr);
    const cv::Mat &image(int cam) const;

    // Replaces cam's points with a fresh detection; returns how many corners.
    int detect(int cam);
    const std::vector<CalibPoint> &points(int cam) const;
    void move_point(int cam, int idx, cv::Point2f image_px);

    bool solve(int cam);
    const CalibSolve &result(int cam) const;
    std::vector<CalibSeam> seams() const;

    // Stitched top view of every solved camera, +Y up, framing all boards.
    cv::Mat render_preview(double px_per_m) const;

    // Writes every solved camera's homography into its slot, plus the car
    // size the layout was measured against.
    void apply(BevConfig &cfg) const;

private:
    struct Cam;

    std::vector<cv::Point2f> undistorted(int cam, const std::vector<cv::Point2f> &raw) const;

    CalibLayout layout_;
    std::vector<std::unique_ptr<CharucoModel>> boards_;
    std::vector<std::vector<cv::Point2d>> world_; // per board, per corner id: car frame
    std::vector<Cam> cams_;
};
