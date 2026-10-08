// dart:ffi bindings to libbev_calib.so (built by hook/build.dart). Mirrors
// calib/bev_calib_api.h.
@DefaultAsset('package:bev_calib/src/ffi/bev_calib_ffi.dart')
library;

// ignore_for_file: non_constant_identifier_names

import 'dart:convert';
import 'dart:ffi';

final class BevCalibSession extends Opaque {}

final class BevCalibIntrinsics extends Opaque {}

final class BevCalibLayoutInfo extends Struct {
  @Array(64)
  external Array<Char> name;
  @Double()
  external double carWidth;
  @Double()
  external double carLength;
  @Int32()
  external int cameras;
  @Int32()
  external int boards;
}

final class BevCalibCameraInfo extends Struct {
  @Int32()
  external int position;
  @Double()
  external double facingDeg;
  @Array(64)
  external Array<Char> lens;
}

final class BevCalibCameraEntry extends Struct {
  @Array(256)
  external Array<Char> id;
  @Array(64)
  external Array<Char> model;
}

final class BevCalibPosition extends Struct {
  @Array(256)
  external Array<Char> camera;
  @Array(64)
  external Array<Char> lens;
  @Int32()
  external int calibrated;
}

final class BevCalibBoardInfo extends Struct {
  @Array(32)
  external Array<Char> dict;
  @Int32()
  external int squaresX;
  @Int32()
  external int squaresY;
  @Int32()
  external int firstId;
  @Double()
  external double squareLen;
  @Double()
  external double markerLen;
  @Double()
  external double x;
  @Double()
  external double y;
  @Double()
  external double yawDeg;
  @Int32()
  external int square;
}

final class BevCalibPoint extends Struct {
  @Float()
  external double x;
  @Float()
  external double y;
  @Double()
  external double worldX;
  @Double()
  external double worldY;
  @Int32()
  external int board;
  @Int32()
  external int corner;
  @Int32()
  external int moved;
  @Int32()
  external int inlier;
  @Int32()
  external int guessed;
}

final class BevCalibSolve extends Struct {
  @Int32()
  external int ok;
  @Int32()
  external int inliers;
  @Double()
  external double rmsPx;
  @Double()
  external double maxPx;
  @Double()
  external double groundRmsMm;
  @Double()
  external double groundMaxMm;
}

final class BevCalibSeam extends Struct {
  @Int32()
  external int camA;
  @Int32()
  external int camB;
  @Int32()
  external int shared;
  @Double()
  external double medianMm;
  @Double()
  external double maxMm;
}

final class BevIntrStatus extends Struct {
  @Int32()
  external int corners;
  @Int32()
  external int usable;
  @Int32()
  external int views;
  @Int32()
  external int width;
  @Int32()
  external int height;
}

final class BevIntrResult extends Struct {
  @Int32()
  external int ok;
  @Int32()
  external int imageW;
  @Int32()
  external int imageH;
  @Int32()
  external int views;
  @Double()
  external double rmsPx;
  @Double()
  external double worstViewPx;
  @Double()
  external double fx;
  @Double()
  external double fy;
  @Double()
  external double cx;
  @Double()
  external double cy;
  @Double()
  external double k1;
  @Double()
  external double k2;
  @Double()
  external double p1;
  @Double()
  external double p2;
  @Double()
  external double k3;
  @Int32()
  external int fisheye;
  @Double()
  external double k4;
}

String charArrayToString(Array<Char> a, int length) {
  final bytes = <int>[];
  for (var i = 0; i < length && a[i] != 0; i++) {
    bytes.add(a[i] & 0xff);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

@Native<Pointer<Char> Function()>()
external Pointer<Char> bev_calib_last_error();

@Native<Int32 Function()>()
external int bev_calib_camera_active();

@Native<Int32 Function()>()
external int bev_calib_cameras_present();

@Native<Int32 Function(Pointer<BevCalibCameraEntry>, Int32)>()
external int bev_calib_camera_list(Pointer<BevCalibCameraEntry> out, int cap);

@Native<Int32 Function(Pointer<Char>, Pointer<Char>, Int32)>()
external int bev_calib_camera_snapshot(Pointer<Char> cameraId, Pointer<Char> jpegPath, int width);

@Native<Int32 Function(Pointer<Char>, Int32, Pointer<BevCalibPosition>)>()
external int bev_calib_config_position(Pointer<Char> configPath, int position, Pointer<BevCalibPosition> out);

@Native<Int32 Function(Pointer<Char>, Int32, Pointer<Char>)>()
external int bev_calib_config_assign(Pointer<Char> configPath, int position, Pointer<Char> cameraId);

@Native<Int32 Function(Pointer<Char>, Int32, Pointer<Char>)>()
external int bev_calib_config_set_lens(Pointer<Char> configPath, int position, Pointer<Char> lens);

@Native<Int32 Function(Pointer<Char>, Pointer<BevCalibLayoutInfo>)>()
external int bev_calib_layout_info(Pointer<Char> path, Pointer<BevCalibLayoutInfo> out);

@Native<Int32 Function(Pointer<Char>, Int32, Pointer<BevCalibCameraInfo>)>()
external int bev_calib_layout_camera(Pointer<Char> path, int index, Pointer<BevCalibCameraInfo> out);

@Native<Int32 Function(Pointer<Char>, Int32, Pointer<BevCalibBoardInfo>)>()
external int bev_calib_layout_board(Pointer<Char> path, int index, Pointer<BevCalibBoardInfo> out);

@Native<Pointer<BevCalibSession> Function(Pointer<Char>, Pointer<Char>, Pointer<Char>)>()
external Pointer<BevCalibSession> bev_calib_open(Pointer<Char> layoutPath, Pointer<Char> lensDir,
    Pointer<Char> configPath);

@Native<Void Function(Pointer<BevCalibSession>)>()
external void bev_calib_close(Pointer<BevCalibSession> s);

@Native<Int32 Function(Pointer<BevCalibSession>, Int32)>()
external int bev_calib_has_lens(Pointer<BevCalibSession> s, int cam);

@Native<Int32 Function(Pointer<BevCalibSession>, Int32, Pointer<Char>, Pointer<Char>)>()
external int bev_calib_set_lens(Pointer<BevCalibSession> s, int cam, Pointer<Char> lensDir, Pointer<Char> lens);

@Native<Int32 Function(Pointer<BevCalibSession>, Int32, Int32)>()
external int bev_calib_capture(Pointer<BevCalibSession> s, int cam, int settleFrames);

@Native<Int32 Function(Pointer<BevCalibSession>, Int32, Pointer<Char>)>()
external int bev_calib_load_image(Pointer<BevCalibSession> s, int cam, Pointer<Char> path);

@Native<Int32 Function(Pointer<BevCalibSession>, Int32, Pointer<Char>)>()
external int bev_calib_save_image(Pointer<BevCalibSession> s, int cam, Pointer<Char> path);

@Native<Int32 Function(Pointer<BevCalibSession>, Int32, Pointer<Int32>, Pointer<Int32>)>()
external int bev_calib_image_size(Pointer<BevCalibSession> s, int cam, Pointer<Int32> w, Pointer<Int32> h);

@Native<Int32 Function(Pointer<BevCalibSession>, Int32)>()
external int bev_calib_detect(Pointer<BevCalibSession> s, int cam);

@Native<Int32 Function(Pointer<BevCalibSession>, Int32)>()
external int bev_calib_point_count(Pointer<BevCalibSession> s, int cam);

@Native<Int32 Function(Pointer<BevCalibSession>, Int32, Int32, Pointer<BevCalibPoint>)>()
external int bev_calib_point(Pointer<BevCalibSession> s, int cam, int index, Pointer<BevCalibPoint> out);

@Native<Int32 Function(Pointer<BevCalibSession>, Int32, Int32, Float, Float)>()
external int bev_calib_move_point(Pointer<BevCalibSession> s, int cam, int index, double x, double y);

@Native<Int32 Function(Pointer<BevCalibSession>, Int32, Pointer<BevCalibSolve>)>()
external int bev_calib_solve(Pointer<BevCalibSession> s, int cam, Pointer<BevCalibSolve> out);

@Native<Int32 Function(Pointer<BevCalibSession>, Int32)>()
external int bev_calib_add_missing(Pointer<BevCalibSession> s, int cam);

@Native<Int32 Function(Pointer<BevCalibSession>, Int32, Int32, Int32, Float, Float)>()
external int bev_calib_place_point(Pointer<BevCalibSession> s, int cam, int board, int corner, double x, double y);

@Native<Int32 Function(Pointer<BevCalibSession>, Int32)>()
external int bev_calib_board_corner_count(Pointer<BevCalibSession> s, int board);

@Native<Int32 Function(Pointer<BevCalibSession>, Int32, Int32, Pointer<Double>, Pointer<Double>)>()
external int bev_calib_board_corner(Pointer<BevCalibSession> s, int board, int corner, Pointer<Double> x,
    Pointer<Double> y);

@Native<Int32 Function(Pointer<BevCalibSession>, Int32, Int32, Int32, Pointer<Char>, Pointer<Double>, Pointer<Double>)>()
external int bev_calib_board_reference(Pointer<BevCalibSession> s, int board, int corner, int width,
    Pointer<Char> pngPath, Pointer<Double> marginM, Pointer<Double> pxPerM);

@Native<Int32 Function(Pointer<BevCalibSession>)>()
external int bev_calib_seam_count(Pointer<BevCalibSession> s);

@Native<Int32 Function(Pointer<BevCalibSession>, Int32, Pointer<BevCalibSeam>)>()
external int bev_calib_seam(Pointer<BevCalibSession> s, int index, Pointer<BevCalibSeam> out);

@Native<Int32 Function(Pointer<BevCalibSession>, Double, Pointer<Char>)>()
external int bev_calib_render_preview(Pointer<BevCalibSession> s, double pxPerM, Pointer<Char> path);

@Native<Int32 Function(Pointer<BevCalibSession>, Pointer<Char>)>()
external int bev_calib_save_config(Pointer<BevCalibSession> s, Pointer<Char> configPath);

@Native<Pointer<BevCalibIntrinsics> Function(Pointer<Char>, Pointer<Char>, Int32, Int32, Double, Double, Int32, Int32)>()
external Pointer<BevCalibIntrinsics> bev_intr_open(Pointer<Char> cameraId, Pointer<Char> dict, int squaresX,
    int squaresY, double squareLen, double markerLen, int legacy, int fisheye);

@Native<Void Function(Pointer<BevCalibIntrinsics>)>()
external void bev_intr_close(Pointer<BevCalibIntrinsics> h);

@Native<Int32 Function(Pointer<BevCalibIntrinsics>, Pointer<Char>, Int32, Pointer<BevIntrStatus>)>()
external int bev_intr_grab(Pointer<BevCalibIntrinsics> h, Pointer<Char> previewPath, int previewWidth,
    Pointer<BevIntrStatus> out);

@Native<Int32 Function(Pointer<BevCalibIntrinsics>)>()
external int bev_intr_add(Pointer<BevCalibIntrinsics> h);

@Native<Int32 Function(Pointer<BevCalibIntrinsics>, Pointer<BevIntrResult>)>()
external int bev_intr_calibrate(Pointer<BevCalibIntrinsics> h, Pointer<BevIntrResult> out);

@Native<Int32 Function(Pointer<BevCalibIntrinsics>, Pointer<Char>)>()
external int bev_intr_save(Pointer<BevCalibIntrinsics> h, Pointer<Char> lensIniPath);
