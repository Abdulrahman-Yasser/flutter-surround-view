#pragma once

// Camera frames read on the CPU, for cameras the GPU can't import directly.
// The live view imports NV12 dma-bufs straight into GL; a USB (UVC) camera
// only offers packed YUYV, so its frames are converted to NV12 here and go
// through the renderer's system-memory upload instead. NV12 frames of a
// camera sharing a view with such a camera are handed over as they are.

#include "dmabuf_frame.h"

#include <libcamera/libcamera.h>

#include <cstdint>
#include <map>
#include <memory>
#include <vector>

class CpuFrames {
public:
    // Whether frames in this format can be read here.
    static bool readable(const libcamera::PixelFormat &format);

    ~CpuFrames();

    // Maps every buffer of the pool; false if one can't be mapped.
    bool map(const std::vector<std::unique_ptr<libcamera::FrameBuffer>> &buffers,
             const libcamera::StreamConfiguration &sc);

    // The frame in buf as NV12 in memory, valid until the next call.
    DmaBufFrame nv12(const libcamera::FrameBuffer *buf);

private:
    struct Map {
        std::vector<const uint8_t *> planes;
        std::vector<int> fds;
    };
    std::map<const libcamera::FrameBuffer *, Map> maps_;
    std::vector<std::pair<void *, size_t>> mmaps_;
    std::vector<uint8_t> nv12_;
    libcamera::PixelFormat format_;
    int width_ = 0, height_ = 0, stride_ = 0;
};
