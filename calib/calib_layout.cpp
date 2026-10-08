#include "calib_layout.h"

#include "bev_config.h"

#include <fstream>
#include <iostream>
#include <set>

static std::string trim(const std::string &s)
{
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return "";
    size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
}

static bool parse_squares(const std::string &val, int &sx, int &sy)
{
    size_t x = val.find_first_of("xX");
    if (x == std::string::npos) return false;
    try {
        sx = std::stoi(val.substr(0, x));
        sy = std::stoi(val.substr(x + 1));
    } catch (...) {
        return false;
    }
    return sx >= 2 && sy >= 2;
}

static bool validate(const std::string &path, const CalibLayout &l)
{
    if (l.cameras.empty() || l.boards.empty()) {
        std::cerr << "[layout] " << path << ": needs at least one [camera] and one [board]\n";
        return false;
    }
    std::set<int> slots;
    for (const CalibCamera &c : l.cameras) {
        if (c.slot < 0 || c.slot >= BevConfig::kMaxSlots || !slots.insert(c.slot).second) {
            std::cerr << "[layout] " << path << ": bad or duplicate camera slot " << c.slot << "\n";
            return false;
        }
    }
    bool charuco = false;
    for (const CalibBoard &b : l.boards) charuco |= !b.square;
    if (!charuco) {
        std::cerr << "[layout] " << path << ": needs at least one ChArUco board to locate the squares\n";
        return false;
    }
    // Two boards sharing a dictionary must not share marker ids, or a corner
    // could not be attributed to one board.
    for (size_t i = 0; i < l.boards.size(); ++i) {
        const CalibBoard &a = l.boards[i];
        if (a.square) {
            if (a.square_len <= 0) {
                std::cerr << "[layout] " << path << ": board " << i << " needs a size\n";
                return false;
            }
            continue;
        }
        if (a.marker_len <= 0 || a.marker_len >= a.square_len) {
            std::cerr << "[layout] " << path << ": board " << i << " marker must be smaller than square\n";
            return false;
        }
        for (size_t j = i + 1; j < l.boards.size(); ++j) {
            const CalibBoard &b = l.boards[j];
            if (b.square || a.dict != b.dict) continue;
            if (a.first_id < b.first_id + b.markers() && b.first_id < a.first_id + a.markers()) {
                std::cerr << "[layout] " << path << ": boards " << i << " and " << j
                          << " overlap in marker ids of " << a.dict << "\n";
                return false;
            }
        }
    }
    return true;
}

bool calib_layout_load(const std::string &path, CalibLayout &out)
{
    std::ifstream in(path);
    if (!in.is_open()) {
        std::cerr << "[layout] cannot open '" << path << "'\n";
        return false;
    }

    out = CalibLayout{};
    enum { GLOBAL, CAMERA, BOARD } section = GLOBAL;
    std::string raw;
    int lineno = 0;
    while (std::getline(in, raw)) {
        ++lineno;
        std::string line = trim(raw.substr(0, raw.find('#')));
        if (line.empty()) continue;

        if (line == "[camera]") { section = CAMERA; out.cameras.emplace_back(); continue; }
        if (line == "[board]")  { section = BOARD;  out.boards.emplace_back();  continue; }
        if (line.front() == '[') {
            std::cerr << "[layout] " << path << ":" << lineno << ": unknown section '" << line << "'\n";
            return false;
        }

        size_t eq = line.find('=');
        if (eq == std::string::npos) {
            std::cerr << "[layout] " << path << ":" << lineno
                      << ": expected 'key = value', got '" << line << "'\n";
            return false;
        }
        std::string key = trim(line.substr(0, eq));
        std::string val = trim(line.substr(eq + 1));

        bool ok = true;
        try {
            if (section == GLOBAL) {
                if      (key == "name")       out.name = val;
                else if (key == "car_width")  out.car_width = std::stod(val);
                else if (key == "car_length") out.car_length = std::stod(val);
                else ok = false;
            } else if (section == CAMERA) {
                CalibCamera &c = out.cameras.back();
                if      (key == "slot")   c.slot = std::stoi(val);
                else if (key == "facing") ok = parse_facing(val, c.facing_deg);
                else if (key == "lens")   c.lens = val;
                else ok = false;
            } else {
                CalibBoard &b = out.boards.back();
                if      (key == "type" && (val == "charuco" || val == "square")) b.square = val == "square";
                else if (key == "size")     b.square_len = std::stod(val);
                else if (key == "dict")     b.dict = val;
                else if (key == "squares")  ok = parse_squares(val, b.squares_x, b.squares_y);
                else if (key == "square")   b.square_len = std::stod(val);
                else if (key == "marker")   b.marker_len = std::stod(val);
                else if (key == "first_id") b.first_id = std::stoi(val);
                else if (key == "legacy")   b.legacy = std::stoi(val) != 0;
                else if (key == "x")        b.x = std::stod(val);
                else if (key == "y")        b.y = std::stod(val);
                else if (key == "yaw")      b.yaw_deg = std::stod(val);
                else ok = false;
            }
        } catch (const std::exception &) {
            ok = false;
        }
        if (!ok) {
            std::cerr << "[layout] " << path << ":" << lineno << ": bad line '" << line << "'\n";
            return false;
        }
    }
    for (CalibBoard &b : out.boards) {
        if (!b.square) continue;
        b.squares_x = b.squares_y = 1;
        b.marker_len = 0;
    }
    return validate(path, out);
}
