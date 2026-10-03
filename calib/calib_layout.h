#pragma once

#include <string>
#include <vector>

// A calibration setup: which cameras take part and where each ChArUco board
// lies on the ground around the car.
//
// Car frame, metres: origin at the car centre, +X right, +Y forward (the same
// convention as BevSlotConfig::facing_deg). A board's (x, y) is its centre;
// yaw is degrees counter-clockwise. At yaw 0 the board's printed top edge
// (the side marker first_id is on) faces +Y.

struct CalibCamera {
    int         slot = 0;            // bev_config.ini [slotN] this camera calibrates
    double      facing_deg = 90.0;
    std::string lens;                // "<lens_dir>/<lens>-lens.ini"; empty = no undistortion
};

struct CalibBoard {
    std::string dict = "4X4_50";
    int    squares_x = 6, squares_y = 8;
    double square_len = 0.090, marker_len = 0.070;
    int    first_id = 0;             // marker ids first_id .. first_id + markers()-1
    bool   legacy = true;
    double x = 0.0, y = 0.0, yaw_deg = 0.0;

    int markers() const { return squares_x * squares_y / 2; }
    int corners() const { return (squares_x - 1) * (squares_y - 1); }
};

struct CalibLayout {
    std::string name;
    double car_width = 1.8, car_length = 4.5;
    std::vector<CalibCamera> cameras;
    std::vector<CalibBoard>  boards;
};

// Returns false with a message on stderr for a malformed file, an unknown
// key, overlapping marker id ranges in one dictionary, or a duplicate slot.
bool calib_layout_load(const std::string &path, CalibLayout &out);
