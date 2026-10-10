#pragma once

// Per-slot BEV geometry helpers shared by main.cpp's --src mode and the
// ivi-homescreen platform view (ihs/bev_pipeline.cpp), so both build their
// homographies and lens lookups from one copy.

#include "bev_config.h"
#include "ipm.h" // mat3

#include <string>

// BEV canvas pixel (top-left origin) -> normalized image uv for a calibrated
// slot. The canvas centre is the car-frame origin, +Y up the canvas.
// The canvas centre shows car-frame point (cx, cy).
mat3 measured_H(const BevSlotConfig &slot, double px_per_m, int bev_w, int bev_h,
                double cx = 0.0, double cy = 0.0);

// Naming-convention lookup for a per-lens-model distortion file:
// "<lens_dir>/<lens_model>-lens.ini". lens_model is used verbatim -- no
// hyphenation normalization -- so "imx219" and "imx-219" are two different
// files, consistently with whatever the user actually typed/saved.
std::string lens_calib_path(const std::string &lens_dir, const std::string &lens_model);

// The renderer's distortion switch: 0 none, 1 pinhole, 2 fisheye.
inline int lens_mode(const BevSlotConfig &slot)
{
    return slot.has_distortion ? (slot.fisheye ? 2 : 1) : 0;
}
