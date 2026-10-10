#include "bev_config.h"

#include <cctype>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>

// hb2i used to be board-metres -> image pixels at 3280x2464, with the BEV
// canvas centred on the board centre (0.27, 0.36). Composing that offset in
// turns it into a car-frame homography that renders identically.
static void legacy_hb2i_to_car(BevSlotConfig &s)
{
    mat3 T;
    T.at(0, 2) = 0.27;
    T.at(1, 2) = 0.36;
    s.hb2i = s.hb2i * T;
    s.hb2i_w = 3280;
    s.hb2i_h = 2464;
}

BevConfig bev_config_defaults()
{
    BevConfig cfg;
    // Slots 0/1 are the two real ChArUco-calibrated test cameras: both
    // mounted 45cm up, 19cm apart (9.5cm either side of center), facing
    // forward -- slot 0 (camA) on the left yawed a little left, slot 1
    // (camB) on the right yawed a little right (toed-out) -- so both get
    // facing_deg=90 (front), not the 90-degree-apart front/right split this
    // template originally assumed. Slots 2/3 are still-unused placeholders
    // for a future back/left camera pair.
    // Recalibrated from street_captures/f_20260623_101125's camA.png/camB.png
    // (a single shared ChArUco board shot, both cameras, not moved between
    // frames) via cv2.findHomography(board-metres -> image-pixels) per
    // camera, RANSAC, then rescaled from that capture's 1640x1232 into
    // 3280x2464 (board-frame, see legacy_hb2i_to_car()). 9 shared corners: median=0.91mm,
    // mean=0.98mm, max=2.40mm overlap alignment error. Supersedes earlier
    // pairs recalibrated the same way from street_captures/20260623_101549
    // (median=1.36mm/mean=1.30mm/max=2.16mm) and captures/20260623_100123
    // (indoor; median=0.77mm/mean=0.86mm/max=2.42mm) -- swap back to whichever
    // matches what's actually being tested, see BUGS_FOUND.md bug #3 for how
    // these are derived and why they must come from one shared shot, not
    // independently plausible ones.
    cfg.slots[0] = BevSlotConfig{
        -0.095, 0.0, 0.45, -30.0, 15.0, 90.0, true,
        mat3{{ 188.9045, -1087.857, 0.6601708, 3025.682, 42.45147, 0.3074604, -482.5418, 1153.304, 1 }}
    };
    cfg.slots[1] = BevSlotConfig{
        0.095, 0.0, 0.45, -30.0, -15.0, 90.0, true,
        mat3{{ 1305.29, -738.869, 0.5491576, 1781.791, 72.92492, -0.150135, 1650.012, 1077.979, 1 }}
    };
    legacy_hb2i_to_car(cfg.slots[0]);
    legacy_hb2i_to_car(cfg.slots[1]);
    for (int i = 2; i < BevConfig::kMaxSlots; ++i) cfg.slots[i].facing_deg = bev_position_facing(i);
    return cfg;
}

static const char *const kPositionNames[kPositionCount] = {
    "front_left", "front_right", "back_left", "back_right", "front", "right", "back", "left",
};
static const double kPositionFacing[kPositionCount] = {135, 45, 225, 315, 90, 0, 270, 180};

const char *bev_position_name(int position)
{
    return position >= 0 && position < kPositionCount ? kPositionNames[position] : nullptr;
}

int bev_position_index(const std::string &name)
{
    for (int i = 0; i < kPositionCount; ++i)
        if (name == kPositionNames[i]) return i;
    return -1;
}

double bev_position_facing(int position)
{
    return position >= 0 && position < kPositionCount ? kPositionFacing[position] : 90.0;
}

bool parse_facing(const std::string &val, double &out)
{
    std::string low = val;
    for (char &c : low) c = (char)std::tolower((unsigned char)c);
    if      (low == "front") { out = 90.0;  return true; }
    else if (low == "right") { out = 0.0;   return true; }
    else if (low == "back")  { out = 270.0; return true; }
    else if (low == "left")  { out = 180.0; return true; }
    if (int p = bev_position_index(low); p >= 0) {
        out = bev_position_facing(p);
        return true;
    }
    try {
        size_t consumed = 0;
        out = std::stod(val, &consumed);
        return consumed == val.size();
    } catch (...) {
        return false;
    }
}

static std::string trim(const std::string &s)
{
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return "";
    size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
}

// Parses a "[front_left]"-style section header, or the older "[slotN]";
// returns false if malformed.
static bool parse_slot_header(const std::string &line, int &idx)
{
    if (line.size() < 3 || line.front() != '[' || line.back() != ']') return false;
    std::string inner = line.substr(1, line.size() - 2);
    idx = bev_position_index(inner);
    if (idx >= 0) return true;
    if (inner.rfind("slot", 0) != 0) return false;
    std::string num = inner.substr(4);
    if (num.empty()) return false;
    try {
        size_t consumed = 0;
        idx = std::stoi(num, &consumed);
        return consumed == num.size();
    } catch (...) {
        return false;
    }
}

bool bev_config_load(const std::string &path, BevConfig &out)
{
    out = bev_config_defaults();

    std::ifstream in(path);
    if (!in.is_open()) {
        std::printf("[config] '%s' not found, using built-in defaults\n", path.c_str());
        return true;
    }

    int current_slot = -1; // -1 = global section
    bool saw_hb2i[BevConfig::kMaxSlots] = {}, saw_hb2i_size[BevConfig::kMaxSlots] = {};
    std::string raw;
    int lineno = 0;
    while (std::getline(in, raw)) {
        ++lineno;
        std::string line = trim(raw);
        if (line.empty() || line[0] == '#') continue;

        if (line.front() == '[') {
            int idx;
            if (!parse_slot_header(line, idx) || idx < 0 || idx >= BevConfig::kMaxSlots) {
                std::cerr << "[config] " << path << ":" << lineno
                          << ": bad section '" << line << "'\n";
                return false;
            }
            current_slot = idx;
            continue;
        }

        size_t eq = line.find('=');
        if (eq == std::string::npos) {
            std::cerr << "[config] " << path << ":" << lineno
                      << ": expected 'key = value', got '" << line << "'\n";
            return false;
        }
        std::string key = trim(line.substr(0, eq));
        std::string val = trim(line.substr(eq + 1));

        try {
            if (current_slot < 0) {
                if      (key == "px_per_m")    out.px_per_m    = std::stod(val);
                else if (key == "overlap_deg") out.overlap_deg = std::stof(val);
                else if (key == "blend_edge")  out.blend_edge  = std::stof(val);
                else if (key == "car_x")       out.car_x       = std::stod(val);
                else if (key == "car_y")       out.car_y       = std::stod(val);
                else if (key == "car_width")   out.car_width   = std::stod(val);
                else if (key == "car_length")  out.car_length  = std::stod(val);
                else {
                    std::cerr << "[config] " << path << ":" << lineno
                              << ": unknown global key '" << key << "'\n";
                    return false;
                }
            } else {
                BevSlotConfig &s = out.slots[current_slot];
                if      (key == "cam_x") s.cam_x = std::stod(val);
                else if (key == "cam_y") s.cam_y = std::stod(val);
                else if (key == "cam_h") s.cam_h = std::stod(val);
                else if (key == "pitch") s.pitch = std::stod(val);
                else if (key == "yaw")   s.yaw   = std::stod(val);
                // Left behind by the removed live-tune; ignored.
                else if (key == "cam_x_delta" || key == "cam_y_delta" || key == "yaw_delta") {}
                else if (key == "hb2i_w") { s.hb2i_w = std::stoi(val); saw_hb2i_size[current_slot] = true; }
                else if (key == "hb2i_h") { s.hb2i_h = std::stoi(val); saw_hb2i_size[current_slot] = true; }
                else if (key == "facing") {
                    if (!parse_facing(val, s.facing_deg)) {
                        std::cerr << "[config] " << path << ":" << lineno
                                  << ": bad facing '" << val
                                  << "' (want front/back/left/right or a degree number)\n";
                        return false;
                    }
                }
                else if (key == "lens_model") s.lens_model = val;
                else if (key == "camera")     s.camera = val;
                else if (key == "view") {
                    std::istringstream iss(val);
                    if (!(iss >> s.view_x0 >> s.view_y0 >> s.view_x1 >> s.view_y1)) {
                        std::cerr << "[config] " << path << ":" << lineno
                                  << ": view needs x0 y0 x1 y1, got '" << val << "'\n";
                        return false;
                    }
                    s.has_view = true;
                }
                else if (key == "hb2i") {
                    std::istringstream iss(val);
                    double v[9];
                    for (double &d : v) {
                        if (!(iss >> d)) {
                            std::cerr << "[config] " << path << ":" << lineno
                                      << ": hb2i needs 9 values, got '" << val << "'\n";
                            return false;
                        }
                    }
                    for (int c = 0; c < 9; ++c) s.hb2i.m[c] = v[c];
                    s.has_hb2i = true;
                    saw_hb2i[current_slot] = true;
                } else {
                    std::cerr << "[config] " << path << ":" << lineno
                              << ": unknown slot key '" << key << "'\n";
                    return false;
                }
            }
        } catch (const std::exception &) {
            std::cerr << "[config] " << path << ":" << lineno
                      << ": malformed number in '" << line << "'\n";
            return false;
        }
    }
    // A file written before hb2i_w/hb2i_h existed holds board-frame matrices.
    for (int i = 0; i < BevConfig::kMaxSlots; ++i)
        if (saw_hb2i[i] && !saw_hb2i_size[i]) legacy_hb2i_to_car(out.slots[i]);
    return true;
}

bool bev_config_save(const std::string &path, const BevConfig &cfg)
{
    // A fresh install has no data directory until something creates it.
    std::error_code ec;
    const std::filesystem::path dir = std::filesystem::path(path).parent_path();
    if (!dir.empty()) std::filesystem::create_directories(dir, ec);
    std::ofstream out(path, std::ios::trunc);
    if (!out.is_open()) {
        std::cerr << "[config] failed to open '" << path << "' for writing\n";
        return false;
    }

    out << std::setprecision(9);
    out << "# libcamera-dmabuf-capture -- multi-camera (--src) BEV defaults.\n"
        << "# Auto-generated by the calibration screen or 'W' at runtime.\n\n";
    out << "px_per_m = "    << cfg.px_per_m    << "\n";
    out << "overlap_deg = " << cfg.overlap_deg << "\n";
    out << "blend_edge = "  << cfg.blend_edge  << "\n";
    out << "car_x = "       << cfg.car_x       << "\n";
    out << "car_y = "       << cfg.car_y       << "\n";
    out << "car_width = "   << cfg.car_width   << "\n";
    out << "car_length = "  << cfg.car_length  << "\n";

    for (int i = 0; i < BevConfig::kMaxSlots; ++i) {
        const BevSlotConfig &s = cfg.slots[i];
        if (s.camera.empty() && !s.has_hb2i && s.lens_model.empty()) continue;
        out << "\n[" << bev_position_name(i) << "]\n";
        if (!s.camera.empty()) out << "camera = " << s.camera << "\n";
        out << "cam_x = " << s.cam_x << "\n";
        out << "cam_y = " << s.cam_y << "\n";
        out << "cam_h = " << s.cam_h << "\n";
        out << "pitch = " << s.pitch << "\n";
        out << "yaw = "   << s.yaw   << "\n";
        out << "facing = " << s.facing_deg << "\n";
        if (s.has_hb2i) {
            out << "hb2i =";
            for (double v : s.hb2i.m) out << " " << v;
            out << "\n";
            out << "hb2i_w = " << s.hb2i_w << "\n";
            out << "hb2i_h = " << s.hb2i_h << "\n";
        }
        if (s.has_view)
            out << "view = " << s.view_x0 << " " << s.view_y0 << " " << s.view_x1 << " " << s.view_y1 << "\n";
        // Only lens_model is persisted (the empty string IS the "unset"
        // sentinel, same role has_hb2i's bool plays for hb2i) -- fx/fy/../
        // k1../lens_calib_w/h are deliberately never written here, see
        // BevSlotConfig::lens_model's comment.
        if (!s.lens_model.empty())
            out << "lens_model = " << s.lens_model << "\n";
    }
    return (bool)out;
}

bool lens_calib_load(const std::string &path, BevSlotConfig &slot)
{
    std::ifstream in(path);
    if (!in.is_open()) return false; // not calibrated yet -- caller decides what to print

    bool have_fx = false, have_fy = false, have_cx = false, have_cy = false;
    bool have_w  = false, have_h  = false;
    BevSlotConfig trial; // build into a scratch copy -- don't touch slot until fully valid

    std::string raw;
    int lineno = 0;
    while (std::getline(in, raw)) {
        ++lineno;
        std::string line = trim(raw);
        if (line.empty() || line[0] == '#') continue;

        size_t eq = line.find('=');
        if (eq == std::string::npos) {
            std::cerr << "[lens] " << path << ":" << lineno
                      << ": expected 'key = value', got '" << line << "'\n";
            return false;
        }
        std::string key = trim(line.substr(0, eq));
        std::string val = trim(line.substr(eq + 1));

        try {
            if      (key == "fx") { trial.fx = std::stod(val); have_fx = true; }
            else if (key == "fy") { trial.fy = std::stod(val); have_fy = true; }
            else if (key == "cx") { trial.cx = std::stod(val); have_cx = true; }
            else if (key == "cy") { trial.cy = std::stod(val); have_cy = true; }
            else if (key == "k1") trial.k1 = std::stod(val);
            else if (key == "k2") trial.k2 = std::stod(val);
            else if (key == "k3") trial.k3 = std::stod(val);
            else if (key == "k4") trial.k4 = std::stod(val);
            else if (key == "model" && (val == "pinhole" || val == "fisheye")) trial.fisheye = val == "fisheye";
            else if (key == "p1") trial.p1 = std::stod(val);
            else if (key == "p2") trial.p2 = std::stod(val);
            else if (key == "calib_w") { trial.lens_calib_w = std::stoi(val); have_w = true; }
            else if (key == "calib_h") { trial.lens_calib_h = std::stoi(val); have_h = true; }
            else {
                std::cerr << "[lens] " << path << ":" << lineno
                          << ": unknown key '" << key << "'\n";
                return false;
            }
        } catch (const std::exception &) {
            std::cerr << "[lens] " << path << ":" << lineno
                      << ": malformed number in '" << line << "'\n";
            return false;
        }
    }

    if (!(have_fx && have_fy && have_cx && have_cy && have_w && have_h)) {
        std::cerr << "[lens] " << path
                  << ": missing required key(s) -- need fx, fy, cx, cy, calib_w, calib_h\n";
        return false;
    }

    // Copy only the distortion-related fields -- slot may already carry real
    // pose/hb2i/lens_model data (this is called with the live slot, or a
    // scratch one main.cpp fills in separately), which a wholesale
    // `slot = trial` would clobber back to BevSlotConfig{}'s defaults.
    slot.fx = trial.fx; slot.fy = trial.fy; slot.cx = trial.cx; slot.cy = trial.cy;
    slot.k1 = trial.k1; slot.k2 = trial.k2; slot.k3 = trial.k3; slot.k4 = trial.k4;
    slot.fisheye = trial.fisheye;
    slot.p1 = trial.p1; slot.p2 = trial.p2;
    slot.lens_calib_w = trial.lens_calib_w;
    slot.lens_calib_h = trial.lens_calib_h;
    slot.has_distortion = true;
    return true;
}
