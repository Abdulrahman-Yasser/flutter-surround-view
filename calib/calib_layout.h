#pragma once

#include <string>
#include <vector>

// A calibration setup: which cameras take part and where each board lies on
// the ground around the car. A board is a ChArUco board or a plain black
// square. Squares carry no ids, so they are found where a camera's ChArUco
// corners predict them; every camera needs a ChArUco board in view.
//
// Car frame, metres: origin at the car centre, +X right, +Y forward (the same
// convention as BevSlotConfig::facing_deg). A board's (x, y) is its centre;
// yaw is degrees counter-clockwise. At yaw 0 the board's printed top edge
// (the side marker first_id is on) faces +Y.

struct CalibCamera {
    int         position = -1;       // BevPosition: which mounted camera this is
    double      facing_deg = 90.0;   // defaults to the position's own direction
    std::string lens;                // "<lens_dir>/<lens>-lens.ini"; empty = no undistortion
};

struct CalibBoard {
    bool   square = false;           // type = square: one black square of side square_len
    std::string dict = "4X4_50";
    int    squares_x = 6, squares_y = 8;
    double square_len = 0.090, marker_len = 0.070;
    int    first_id = 0;             // marker ids first_id .. first_id + markers()-1
    bool   legacy = true;
    double x = 0.0, y = 0.0, yaw_deg = 0.0;

    int markers() const { return square ? 0 : squares_x * squares_y / 2; }
    int corners() const { return square ? 4 : (squares_x - 1) * (squares_y - 1); }
};

struct CalibLayout {
    std::string name;
    double car_width = 1.8, car_length = 4.5;
    std::vector<CalibCamera> cameras;
    std::vector<CalibBoard>  boards;
};

// Returns false with a message on stderr for a malformed file, an unknown
// key, overlapping marker id ranges in one dictionary, or a missing or
// repeated camera position.
bool calib_layout_load(const std::string &path, CalibLayout &out);
