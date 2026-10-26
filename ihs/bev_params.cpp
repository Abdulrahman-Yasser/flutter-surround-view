#include "bev_params.h"

#include <cstdio>
#include <cstdlib>

namespace {

std::string trim(const std::string &s)
{
    size_t b = s.find_first_not_of(" \t\r");
    if (b == std::string::npos) return "";
    size_t e = s.find_last_not_of(" \t\r");
    return s.substr(b, e - b + 1);
}

bool to_double(const std::string &v, double &out)
{
    if (v.empty()) return false;
    char *end = nullptr;
    const double d = std::strtod(v.c_str(), &end);
    if (*end != '\0') return false;
    out = d;
    return true;
}

bool to_int(const std::string &v, int &out)
{
    if (v.empty()) return false;
    char *end = nullptr;
    const long l = std::strtol(v.c_str(), &end, 10);
    if (*end != '\0') return false;
    out = (int)l;
    return true;
}

bool to_bool(const std::string &v, bool &out)
{
    if (v == "1" || v == "true" || v == "yes" || v == "on")  { out = true;  return true; }
    if (v == "0" || v == "false" || v == "no" || v == "off") { out = false; return true; }
    return false;
}

std::string resolve_path(const std::string &v, const std::string &assets_dir)
{
    static constexpr char kAsset[] = "asset:";
    if (v.compare(0, sizeof(kAsset) - 1, kAsset) != 0) return v;
    const std::string rel = v.substr(sizeof(kAsset) - 1);
    return assets_dir.empty() ? rel : assets_dir + "/" + rel;
}

} // namespace

bool bev_params_parse(const uint8_t *data, size_t size, const std::string &assets_dir,
                      BevParams &out, std::string &error)
{
    out = BevParams{};
    const std::string text(data ? reinterpret_cast<const char *>(data) : "", data ? size : 0);

    bool mode_set = false;

    size_t pos = 0;
    int lineno = 0;
    while (pos <= text.size()) {
        size_t nl = text.find('\n', pos);
        if (nl == std::string::npos) nl = text.size();
        const std::string line = trim(text.substr(pos, nl - pos));
        pos = nl + 1;
        ++lineno;
        if (line.empty() || line[0] == '#') continue;

        const size_t eq = line.find('=');
        if (eq == std::string::npos) {
            error = "line " + std::to_string(lineno) + ": expected key=value, got '" + line + "'";
            return false;
        }
        const std::string key = trim(line.substr(0, eq));
        const std::string val = trim(line.substr(eq + 1));

        auto bad = [&](const char *what) {
            error = "line " + std::to_string(lineno) + ": " + key + "=" + val + " is not " + what;
            return false;
        };
        auto num_set = [&](double &field, bool &set) {
            if (!to_double(val, field)) return bad("a number");
            set = true;
            return true;
        };

        if (key == "mode") {
            if      (val == "camera")   out.mode = BevParams::Mode::Camera;
            else if (val == "surround") out.mode = BevParams::Mode::Surround;
            else if (val == "pattern")  out.mode = BevParams::Mode::Pattern;
            else return bad("camera|surround|pattern");
            mode_set = true;
        } else if (key == "fit") {
            if      (val == "contain") out.fit = BevParams::Fit::Contain;
            else if (val == "cover")   out.fit = BevParams::Fit::Cover;
            else if (val == "fill")    out.fit = BevParams::Fit::Fill;
            else return bad("contain|cover|fill");
        } else if (key == "ring_size") {
            if (!to_int(val, out.ring_size) || out.ring_size < 2 || out.ring_size > 6)
                return bad("an integer in 2..6");
        } else if (key == "scanout") {
            if (!to_bool(val, out.scanout)) return bad("a boolean");
        } else if (key == "packed_zero_copy") {
            if (!to_bool(val, out.packed_zero_copy)) return bad("a boolean");
        } else if (key == "camera_id") {
            out.camera_id = val;
        } else if (key == "camera_index") {
            if (!to_int(val, out.camera_index) || out.camera_index < 0) return bad("a camera index");
        } else if (key == "width") {
            if (!to_int(val, out.width) || out.width < 0) return bad("a width");
        } else if (key == "height") {
            if (!to_int(val, out.height) || out.height < 0) return bad("a height");
        } else if (key == "pattern_fps") {
            if (!to_double(val, out.pattern_fps) || out.pattern_fps < 0.0)
                return bad("a frame rate (0 = uncapped)");
        } else if (key == "camera_fps") {
            if (!to_double(val, out.camera_fps) || out.camera_fps < 0.0)
                return bad("a frame rate (0 = leave it to auto-exposure)");
        } else if (key == "tuning_file") {
            out.tuning_file = resolve_path(val, assets_dir);
        } else if (key == "px_per_m") {
            if (!num_set(out.px_per_m, out.px_per_m_set)) return false;
        } else if (key == "src") {
            out.sources.push_back(val);
        } else if (key == "config") {
            out.config_path = resolve_path(val, assets_dir);
        } else if (key == "lens_dir") {
            out.lens_dir = resolve_path(val, assets_dir);
        } else if (key == "undistort") {
            if (!to_double(val, out.undistort) || out.undistort < 0.0) return bad("a zoom, 0 = off");
        } else if (key == "blend") {
            if (val != "feather" && val != "coverage")
                return bad("feather|coverage");
            out.blend = val;
        } else {
            std::fprintf(stderr, "[bev/params] line %d: unknown key '%s' ignored\n",
                         lineno, key.c_str());
        }
    }

    for (size_t i = 0; i < out.sources.size(); ++i) out.cfg_slots.push_back((int)i);

    if (!mode_set && !out.sources.empty()) out.mode = BevParams::Mode::Surround;
    if (out.mode == BevParams::Mode::Surround && out.sources.empty()) {
        error = "mode=surround needs src=camera:<index> or src=position:<name>";
        return false;
    }
    return true;
}
