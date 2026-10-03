// C ABI of libbev_calib.so, the ChArUco calibration library. Dart
// (flutter/bev_calib, via @Native) is the only consumer.
//
// Never use the cameras while a libbev_view.so view is live: libcamera allows
// one camera manager per process, so opening one here waits for the view's to
// be gone, and the view waits for this library's in turn.
//
// Calls returning int32_t give 1 (or a count) on success and 0 or -1 on
// failure, with the reason in bev_calib_last_error() on the calling thread.
// A handle may be used from any thread, one call at a time.

#ifndef BEV_CALIB_API_H_
#define BEV_CALIB_API_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define BEV_CALIB_EXPORT __attribute__((visibility("default")))

BEV_CALIB_EXPORT const char *bev_calib_last_error(void);

// 1 while this library holds a camera manager.
BEV_CALIB_EXPORT int32_t bev_calib_camera_active(void);

// Cameras libcamera enumerates, or -1.
BEV_CALIB_EXPORT int32_t bev_calib_cameras_present(void);

// ── Layout files ─────────────────────────────────────────────────────────────

typedef struct BevCalibLayoutInfo {
    char name[64];
    double car_width, car_length;
    int32_t cameras, boards;
} BevCalibLayoutInfo;

typedef struct BevCalibCameraInfo {
    int32_t slot;               // bev_config.ini slot, also the libcamera index
    double facing_deg;
    char lens[64];
} BevCalibCameraInfo;

typedef struct BevCalibBoardInfo {
    char dict[32];
    int32_t squares_x, squares_y, first_id;
    double square_len, marker_len;
    double x, y, yaw_deg;       // centre in the car frame, metres / degrees
} BevCalibBoardInfo;

BEV_CALIB_EXPORT int32_t bev_calib_layout_info(const char *path, BevCalibLayoutInfo *out);
BEV_CALIB_EXPORT int32_t bev_calib_layout_camera(const char *path, int32_t index, BevCalibCameraInfo *out);
BEV_CALIB_EXPORT int32_t bev_calib_layout_board(const char *path, int32_t index, BevCalibBoardInfo *out);

// ── Surround (extrinsic) calibration over a layout ───────────────────────────

typedef struct BevCalibSession BevCalibSession;

typedef struct BevCalibPoint {
    float x, y;                 // still pixel
    double world_x, world_y;    // car frame, metres
    int32_t board, corner, moved, inlier;
} BevCalibPoint;

typedef struct BevCalibSolve {
    int32_t ok, inliers;
    double rms_px, max_px;
    double ground_rms_mm, ground_max_mm;
} BevCalibSolve;

typedef struct BevCalibSeam {
    int32_t cam_a, cam_b, shared;
    double median_mm, max_mm;
} BevCalibSeam;

// Cameras are indexed in layout order. A lens file missing from lens_dir is
// not an error; bev_calib_has_lens() reports it.
BEV_CALIB_EXPORT BevCalibSession *bev_calib_open(const char *layout_path, const char *lens_dir);
BEV_CALIB_EXPORT void bev_calib_close(BevCalibSession *s);
BEV_CALIB_EXPORT int32_t bev_calib_has_lens(BevCalibSession *s, int32_t cam);

// Full-resolution still from the camera's slot, after settle_frames frames
// of auto exposure. Blocks for a few seconds.
BEV_CALIB_EXPORT int32_t bev_calib_capture(BevCalibSession *s, int32_t cam, int32_t settle_frames);
BEV_CALIB_EXPORT int32_t bev_calib_load_image(BevCalibSession *s, int32_t cam, const char *path);
BEV_CALIB_EXPORT int32_t bev_calib_save_image(BevCalibSession *s, int32_t cam, const char *path);
BEV_CALIB_EXPORT int32_t bev_calib_image_size(BevCalibSession *s, int32_t cam, int32_t *w, int32_t *h);

BEV_CALIB_EXPORT int32_t bev_calib_detect(BevCalibSession *s, int32_t cam);
BEV_CALIB_EXPORT int32_t bev_calib_point_count(BevCalibSession *s, int32_t cam);
BEV_CALIB_EXPORT int32_t bev_calib_point(BevCalibSession *s, int32_t cam, int32_t index, BevCalibPoint *out);
BEV_CALIB_EXPORT int32_t bev_calib_move_point(BevCalibSession *s, int32_t cam, int32_t index, float x, float y);
BEV_CALIB_EXPORT int32_t bev_calib_solve(BevCalibSession *s, int32_t cam, BevCalibSolve *out);

// Recomputes the seams between solved cameras; then read them by index.
BEV_CALIB_EXPORT int32_t bev_calib_seam_count(BevCalibSession *s);
BEV_CALIB_EXPORT int32_t bev_calib_seam(BevCalibSession *s, int32_t index, BevCalibSeam *out);

BEV_CALIB_EXPORT int32_t bev_calib_render_preview(BevCalibSession *s, double px_per_m, const char *path);

// Loads config_path (defaults if missing), writes every solved camera's
// homography into its slot, and saves it back.
BEV_CALIB_EXPORT int32_t bev_calib_save_config(BevCalibSession *s, const char *config_path);

// ── Lens (intrinsic) calibration ─────────────────────────────────────────────

typedef struct BevCalibIntrinsics BevCalibIntrinsics;

typedef struct BevIntrStatus {
    int32_t corners, usable, views;
    int32_t width, height;
} BevIntrStatus;

typedef struct BevIntrResult {
    int32_t ok, image_w, image_h, views;
    double rms_px, worst_view_px;
    double fx, fy, cx, cy;
    double k1, k2, p1, p2, k3;
} BevIntrResult;

// Streams camera_index at full resolution until closed.
BEV_CALIB_EXPORT BevCalibIntrinsics *bev_intr_open(int32_t camera_index, const char *dict,
                                                   int32_t squares_x, int32_t squares_y,
                                                   double square_len, double marker_len, int32_t legacy);
BEV_CALIB_EXPORT void bev_intr_close(BevCalibIntrinsics *h);

// Grabs the newest frame, detects the board, and writes a JPEG of it scaled
// to preview_width with the detection and every kept view's corners drawn.
BEV_CALIB_EXPORT int32_t bev_intr_grab(BevCalibIntrinsics *h, const char *preview_path,
                                       int32_t preview_width, BevIntrStatus *out);
// Keeps the last grab as a view. Returns the view count, or -1 if unusable.
BEV_CALIB_EXPORT int32_t bev_intr_add(BevCalibIntrinsics *h);
BEV_CALIB_EXPORT int32_t bev_intr_calibrate(BevCalibIntrinsics *h, BevIntrResult *out);
// Writes the last calibrate() result in the <lens>-lens.ini format.
BEV_CALIB_EXPORT int32_t bev_intr_save(BevCalibIntrinsics *h, const char *lens_ini_path);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // BEV_CALIB_API_H_
