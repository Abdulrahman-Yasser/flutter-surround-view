#pragma once

#include <opencv2/core.hpp>

#include <memory>

// One libcamera camera streaming at its full sensor resolution, for the
// calibration stills. CPU only: frames are mmapped YUV420 converted to BGR.
//
// Only one CameraManager may exist per process, and libbev_view.so owns one
// while a view is live; the constructor waits for that one to go away first.
class StillCamera {
public:
    // Cameras libcamera enumerates; throws std::runtime_error.
    static int count();

    explicit StillCamera(int index); // throws std::runtime_error
    ~StillCamera();

    // The newest frame, waiting for one if none arrived since the last call.
    cv::Mat grab(int timeout_ms = 3000);
    cv::Size size() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

// Live CameraManager instances owned by this library (0 or 1).
int still_camera_manager_count();
