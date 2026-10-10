// Offline front end to CalibSession: runs a layout over still images on disk
// and prints what the app's calibration screen would show.
//
//   bev-calib <layout.ini> <cam0.png> [<cam1.png> ...] [--lens-dir DIR]
//             [--preview out.png] [--ppm N] [--overlay-dir DIR]
//   bev-calib --intrinsics <layout.ini> <photo...> [--lens-out file] [--fisheye]
//             (lens calibration against the layout's first board)

#include "bev_config.h"
#include "calib_session.h"
#include "intrinsics.h"

#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

#include <cstdio>
#include <cstring>
#include <exception>
#include <string>
#include <vector>

static void usage()
{
    std::fprintf(stderr,
        "usage: bev-calib <layout.ini> <image per [camera] in order...>\n"
        "                 [--lens-dir DIR] [--preview out.png] [--ppm N] [--overlay-dir DIR]\n"
        "       bev-calib --intrinsics <layout.ini> <photo...> [--lens-out file] [--fisheye]\n");
}

static int run_intrinsics(const std::vector<std::string> &pos, const std::string &lens_out, bool fisheye)
{
    CalibLayout layout;
    if (!calib_layout_load(pos[0], layout)) return 1;
    IntrinsicsCalib calib(layout.boards[0], fisheye);
    for (size_t i = 1; i < pos.size(); ++i) {
        cv::Mat img = cv::imread(pos[i]);
        if (img.empty()) {
            std::fprintf(stderr, "cannot read %s\n", pos[i].c_str());
            return 1;
        }
        IntrinsicsShot shot = calib.detect(img);
        bool kept = calib.add(shot, img.size());
        std::printf("%s: %zu corners%s\n", pos[i].c_str(), shot.ids.size(), kept ? "" : " (skipped)");
    }
    IntrinsicsResult r = calib.calibrate();
    if (!r.ok) {
        std::fprintf(stderr, "need at least 3 usable photos\n");
        return 1;
    }
    std::printf("%d views at %dx%d: rms=%.3fpx worst view=%.3fpx\n", r.views, r.image_w, r.image_h,
                r.rms_px, r.worst_view_px);
    std::printf("fx=%.2f fy=%.2f cx=%.2f cy=%.2f\n", r.fx, r.fy, r.cx, r.cy);
    if (fisheye) std::printf("fisheye k1=%.5f k2=%.5f k3=%.5f k4=%.5f\n", r.k1, r.k2, r.k3, r.k4);
    else         std::printf("k1=%.5f k2=%.5f p1=%.5f p2=%.5f k3=%.5f\n", r.k1, r.k2, r.p1, r.p2, r.k3);
    if (!lens_out.empty()) {
        if (!IntrinsicsCalib::save_lens_ini(lens_out, r)) return 1;
        std::printf("wrote %s\n", lens_out.c_str());
    }
    return 0;
}

int main(int argc, char **argv)
{
    std::vector<std::string> pos;
    std::string lens_dir = ".", preview, overlay_dir, lens_out;
    bool intrinsics = false, fisheye = false;
    double ppm = 200.0;
    for (int i = 1; i < argc; ++i) {
        auto next = [&]() -> std::string {
            if (i + 1 >= argc) { usage(); std::exit(2); }
            return argv[++i];
        };
        if      (!std::strcmp(argv[i], "--lens-dir"))    lens_dir = next();
        else if (!std::strcmp(argv[i], "--preview"))     preview = next();
        else if (!std::strcmp(argv[i], "--ppm"))         ppm = std::stod(next());
        else if (!std::strcmp(argv[i], "--overlay-dir")) overlay_dir = next();
        else if (!std::strcmp(argv[i], "--lens-out"))    lens_out = next();
        else if (!std::strcmp(argv[i], "--intrinsics"))  intrinsics = true;
        else if (!std::strcmp(argv[i], "--fisheye"))     fisheye = true;
        else if (argv[i][0] == '-') { usage(); return 2; }
        else pos.push_back(argv[i]);
    }
    if (pos.size() < 2) { usage(); return 2; }
    if (intrinsics) {
        try {
            return run_intrinsics(pos, lens_out, fisheye);
        } catch (const std::exception &e) {
            std::fprintf(stderr, "error: %s\n", e.what());
            return 1;
        }
    }

    CalibLayout layout;
    if (!calib_layout_load(pos[0], layout)) return 1;
    if (pos.size() - 1 != layout.cameras.size()) {
        std::fprintf(stderr, "layout '%s' has %zu cameras, got %zu images\n",
                     layout.name.c_str(), layout.cameras.size(), pos.size() - 1);
        return 2;
    }

    try {
        CalibSession s(layout, lens_dir);
        int failed = 0;
        for (int c = 0; c < s.cameras(); ++c) {
            cv::Mat img = cv::imread(pos[c + 1]);
            if (img.empty()) {
                std::fprintf(stderr, "cannot read %s\n", pos[c + 1].c_str());
                return 1;
            }
            s.set_image(c, img);
            int n = s.detect(c);
            bool ok = s.solve(c);
            const CalibSolve &r = s.result(c);
            std::printf("camera %d (%s, %s, %dx%d): %d corners", c, bev_position_name(layout.cameras[c].position),
                        pos[c + 1].c_str(), img.cols, img.rows, n);
            if (!ok) {
                std::printf(" -- solve failed\n");
                ++failed;
                continue;
            }
            std::printf(", %d inliers, reproj rms=%.2fpx max=%.2fpx, ground rms=%.2fmm max=%.2fmm\n",
                        r.inliers, r.rms_px, r.max_px, r.ground_rms_mm, r.ground_max_mm);
            std::printf("  hb2i =");
            for (int col = 0; col < 3; ++col)
                for (int row = 0; row < 3; ++row)
                    std::printf(" %.7g", r.hb2i(row, col));
            std::printf("\n");

            if (!overlay_dir.empty()) {
                cv::Mat o = img.clone();
                for (const CalibPoint &p : s.points(c))
                    cv::circle(o, p.image, 6, p.guessed  ? cv::Scalar(160, 160, 160)
                                              : p.inlier ? cv::Scalar(0, 255, 0)
                                                         : cv::Scalar(0, 0, 255), 2);
                cv::imwrite(overlay_dir + "/cam" + std::to_string(c) + "_corners.png", o);
            }
        }

        for (const CalibSeam &sm : s.seams())
            std::printf("seam cam%d/cam%d: %d shared corners, median=%.2fmm max=%.2fmm\n",
                        sm.cam_a, sm.cam_b, sm.shared, sm.median_mm, sm.max_mm);

        if (!preview.empty()) {
            cv::imwrite(preview, s.render_preview(ppm));
            std::printf("wrote %s\n", preview.c_str());
        }
        return failed ? 1 : 0;
    } catch (const std::exception &e) {
        std::fprintf(stderr, "error: %s\n", e.what());
        return 1;
    }
}
