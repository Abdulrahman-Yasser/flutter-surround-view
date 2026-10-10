#pragma once

#include <opencv2/core.hpp>

#include <memory>
#include <string>
#include <vector>

// One libcamera camera streaming at its full sensor resolution, for the
// calibration stills. CPU only: frames are mmapped and converted to BGR.
//
// Only one CameraManager may exist per process, and libbev_view.so owns one
// while a view is live; the constructor waits for that one to go away first.
class StillCamera {
public:
    struct Info {
        std::string id;     // Camera::id(), what bev_config.ini's camera = holds
        std::string model;  // the sensor or USB product name, for people
    };
    // Cameras libcamera enumerates; throws std::runtime_error.
    static std::vector<Info> list();

    explicit StillCamera(const std::string &id); // throws std::runtime_error
    ~StillCamera();

    // The newest frame, waiting for one if none arrived since the last call.
    cv::Mat grab(int timeout_ms = 3000);
    // A frame once auto exposure and white balance have settled: at least
    // min_frames, then until the colour stops changing between frames, or
    // max_seconds. A USB camera in a dim room can take seconds.
    cv::Mat settled(int min_frames, double max_seconds = 8.0);
    cv::Size size() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

// Live CameraManager instances owned by this library (0 or 1).
int still_camera_manager_count();
