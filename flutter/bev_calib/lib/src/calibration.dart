import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';

import 'ffi/bev_calib_ffi.dart';

class CalibrationException implements Exception {
  CalibrationException(this.message);

  final String message;

  @override
  String toString() => message;
}

// The native error is thread-local, so it has to be read in the same
// synchronous stretch as the call that failed.
String _lastError() => bev_calib_last_error().cast<Utf8>().toDartString();

T _withString<T>(String s, T Function(Pointer<Char>) body) {
  final p = s.toNativeUtf8();
  try {
    return body(p.cast<Char>());
  } finally {
    calloc.free(p);
  }
}

void _check(int result) {
  if (result <= 0) throw CalibrationException(_lastError());
}

class LayoutCamera {
  const LayoutCamera({required this.slot, required this.facingDeg, required this.lens});

  final int slot;
  final double facingDeg;
  final String lens;

  String get facingLabel => switch (((facingDeg % 360) + 360) % 360) {
        90 => 'front',
        270 => 'back',
        180 => 'left',
        0 => 'right',
        final d => '${d.toStringAsFixed(0)}°',
      };
}

class LayoutBoard {
  const LayoutBoard({
    required this.dict,
    required this.squaresX,
    required this.squaresY,
    required this.firstId,
    required this.squareLen,
    required this.markerLen,
    required this.x,
    required this.y,
    required this.yawDeg,
  });

  final String dict;
  final int squaresX, squaresY, firstId;
  final double squareLen, markerLen;
  final double x, y, yawDeg;

  double get width => squaresX * squareLen;
  double get height => squaresY * squareLen;
}

/// A calibration setup file: which cameras take part and where the boards lie.
class CalibLayout {
  CalibLayout._(this.path, this.name, this.carWidth, this.carLength, this.cameras, this.boards);

  final String path;
  final String name;
  final double carWidth, carLength;
  final List<LayoutCamera> cameras;
  final List<LayoutBoard> boards;

  static CalibLayout load(String path) {
    return _withString(path, (p) {
      return using((arena) {
        final info = arena<BevCalibLayoutInfo>();
        _check(bev_calib_layout_info(p, info));
        final cam = arena<BevCalibCameraInfo>();
        final cameras = <LayoutCamera>[];
        for (var i = 0; i < info.ref.cameras; i++) {
          _check(bev_calib_layout_camera(p, i, cam));
          cameras.add(LayoutCamera(
            slot: cam.ref.slot,
            facingDeg: cam.ref.facingDeg,
            lens: charArrayToString(cam.ref.lens, 64),
          ));
        }
        final b = arena<BevCalibBoardInfo>();
        final boards = <LayoutBoard>[];
        for (var i = 0; i < info.ref.boards; i++) {
          _check(bev_calib_layout_board(p, i, b));
          boards.add(LayoutBoard(
            dict: charArrayToString(b.ref.dict, 32),
            squaresX: b.ref.squaresX,
            squaresY: b.ref.squaresY,
            firstId: b.ref.firstId,
            squareLen: b.ref.squareLen,
            markerLen: b.ref.markerLen,
            x: b.ref.x,
            y: b.ref.y,
            yawDeg: b.ref.yawDeg,
          ));
        }
        final name = charArrayToString(info.ref.name, 64);
        return CalibLayout._(path, name.isEmpty ? path.split('/').last : name, info.ref.carWidth,
            info.ref.carLength, cameras, boards);
      });
    });
  }

  /// Every readable layout in [dir], by name. Broken files are skipped.
  static List<CalibLayout> loadAll(String dir) {
    final d = Directory(dir);
    if (!d.existsSync()) return const [];
    final out = <CalibLayout>[];
    for (final f in d.listSync().whereType<File>().where((f) => f.path.endsWith('.ini'))) {
      try {
        out.add(load(f.path));
      } on CalibrationException {
        // A half-edited layout shouldn't hide the others.
      }
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }
}

class CalibPointInfo {
  const CalibPointInfo({
    required this.index,
    required this.x,
    required this.y,
    required this.worldX,
    required this.worldY,
    required this.board,
    required this.corner,
    required this.moved,
    required this.inlier,
  });

  final int index;
  final double x, y;
  final double worldX, worldY;
  final int board, corner;
  final bool moved, inlier;
}

class SolveResult {
  const SolveResult({
    required this.ok,
    required this.inliers,
    required this.rmsPx,
    required this.maxPx,
    required this.groundRmsMm,
    required this.groundMaxMm,
  });

  static const none = SolveResult(ok: false, inliers: 0, rmsPx: 0, maxPx: 0, groundRmsMm: 0, groundMaxMm: 0);

  final bool ok;
  final int inliers;
  final double rmsPx, maxPx, groundRmsMm, groundMaxMm;
}

class SeamResult {
  const SeamResult({
    required this.camA,
    required this.camB,
    required this.shared,
    required this.medianMm,
    required this.maxMm,
  });

  final int camA, camB, shared;
  final double medianMm, maxMm;
}

/// One surround calibration run over a [CalibLayout]. Cameras are indexed in
/// layout order. Slow calls run on a background isolate.
class CalibrationSession {
  CalibrationSession._(this._address, this.layout);

  final int _address;
  final CalibLayout layout;
  bool _closed = false;

  Pointer<BevCalibSession> get _h {
    if (_closed) throw StateError('session closed');
    return Pointer<BevCalibSession>.fromAddress(_address);
  }

  static CalibrationSession open(CalibLayout layout, {required String lensDir}) {
    final h = _withString(layout.path, (lp) => _withString(lensDir, (ld) => bev_calib_open(lp, ld)));
    if (h == nullptr) throw CalibrationException(_lastError());
    return CalibrationSession._(h.address, layout);
  }

  bool hasLens(int cam) => bev_calib_has_lens(_h, cam) == 1;

  Future<void> capture(int cam, {int settleFrames = 20}) {
    final a = _h.address;
    return Isolate.run(() => _check(bev_calib_capture(Pointer.fromAddress(a), cam, settleFrames)));
  }

  Future<void> loadImage(int cam, String path) {
    final a = _h.address;
    return Isolate.run(
        () => _withString(path, (p) => _check(bev_calib_load_image(Pointer.fromAddress(a), cam, p))));
  }

  Future<void> saveImage(int cam, String path) {
    final a = _h.address;
    return Isolate.run(
        () => _withString(path, (p) => _check(bev_calib_save_image(Pointer.fromAddress(a), cam, p))));
  }

  (int, int) imageSize(int cam) {
    return using((arena) {
      final w = arena<Int32>(), h = arena<Int32>();
      _check(bev_calib_image_size(_h, cam, w, h));
      return (w.value, h.value);
    });
  }

  Future<int> detect(int cam) {
    final a = _h.address;
    return Isolate.run(() {
      final n = bev_calib_detect(Pointer.fromAddress(a), cam);
      if (n < 0) throw CalibrationException(_lastError());
      return n;
    });
  }

  List<CalibPointInfo> points(int cam) {
    return using((arena) {
      final p = arena<BevCalibPoint>();
      final n = bev_calib_point_count(_h, cam);
      return [
        for (var i = 0; i < n; i++)
          if (bev_calib_point(_h, cam, i, p) == 1)
            CalibPointInfo(
              index: i,
              x: p.ref.x,
              y: p.ref.y,
              worldX: p.ref.worldX,
              worldY: p.ref.worldY,
              board: p.ref.board,
              corner: p.ref.corner,
              moved: p.ref.moved != 0,
              inlier: p.ref.inlier != 0,
            ),
      ];
    });
  }

  void movePoint(int cam, int index, double x, double y) => _check(bev_calib_move_point(_h, cam, index, x, y));

  /// Solves [cam]; a camera with too few corners gives [SolveResult.none].
  SolveResult solve(int cam) {
    return using((arena) {
      final r = arena<BevCalibSolve>();
      if (bev_calib_solve(_h, cam, r) != 1) return SolveResult.none;
      return SolveResult(
        ok: true,
        inliers: r.ref.inliers,
        rmsPx: r.ref.rmsPx,
        maxPx: r.ref.maxPx,
        groundRmsMm: r.ref.groundRmsMm,
        groundMaxMm: r.ref.groundMaxMm,
      );
    });
  }

  List<SeamResult> seams() {
    return using((arena) {
      final m = arena<BevCalibSeam>();
      final n = bev_calib_seam_count(_h);
      return [
        for (var i = 0; i < n; i++)
          if (bev_calib_seam(_h, i, m) == 1)
            SeamResult(
              camA: m.ref.camA,
              camB: m.ref.camB,
              shared: m.ref.shared,
              medianMm: m.ref.medianMm,
              maxMm: m.ref.maxMm,
            ),
      ];
    });
  }

  /// Picks a scale that frames the layout in roughly [targetPx] pixels.
  double previewScale({double targetPx = 1400}) {
    var ext = math.max(layout.carWidth, layout.carLength);
    for (final b in layout.boards) {
      ext = math.max(ext, 2 * (math.max(b.x.abs(), b.y.abs()) + math.max(b.width, b.height)));
    }
    return targetPx / (ext + 1.0);
  }

  Future<void> renderPreview(String path, {double? pxPerM}) {
    final a = _h.address;
    final ppm = pxPerM ?? previewScale();
    return Isolate.run(() =>
        _withString(path, (p) => _check(bev_calib_render_preview(Pointer.fromAddress(a), ppm, p))));
  }

  void saveConfig(String configPath) =>
      _withString(configPath, (p) => _check(bev_calib_save_config(_h, p)));

  void close() {
    if (_closed) return;
    bev_calib_close(_h);
    _closed = true;
  }
}

class BoardSpec {
  const BoardSpec({
    this.dict = '4X4_50',
    this.squaresX = 5,
    this.squaresY = 8,
    this.squareLen = 0.050,
    this.markerLen = 0.037,
    this.legacy = true,
  });

  final String dict;
  final int squaresX, squaresY;
  final double squareLen, markerLen;
  final bool legacy;
}

class IntrinsicsStatus {
  const IntrinsicsStatus(this.corners, this.usable, this.views, this.width, this.height);

  final int corners;
  final bool usable;
  final int views, width, height;
}

class IntrinsicsResult {
  const IntrinsicsResult({
    required this.imageW,
    required this.imageH,
    required this.views,
    required this.rmsPx,
    required this.worstViewPx,
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
    required this.dist,
  });

  final int imageW, imageH, views;
  final double rmsPx, worstViewPx;
  final double fx, fy, cx, cy;
  final List<double> dist; // k1, k2, p1, p2, k3
}

/// Lens calibration on one live camera. Keep at most one call in flight.
class IntrinsicsSession {
  IntrinsicsSession._(this._address);

  final int _address;
  bool _closed = false;

  Pointer<BevCalibIntrinsics> get _h => Pointer<BevCalibIntrinsics>.fromAddress(_address);

  static Future<IntrinsicsSession> open(int camera, BoardSpec board) async {
    final address = await Isolate.run(() => _withString(board.dict, (d) {
          final h = bev_intr_open(camera, d, board.squaresX, board.squaresY, board.squareLen,
              board.markerLen, board.legacy ? 1 : 0);
          if (h == nullptr) throw CalibrationException(_lastError());
          return h.address;
        }));
    return IntrinsicsSession._(address);
  }

  Future<IntrinsicsStatus> grab(String previewPath, {int previewWidth = 960}) {
    final a = _address;
    return Isolate.run(() => using((arena) {
          final s = arena<BevIntrStatus>();
          _withString(previewPath, (p) => _check(bev_intr_grab(Pointer.fromAddress(a), p, previewWidth, s)));
          return IntrinsicsStatus(s.ref.corners, s.ref.usable != 0, s.ref.views, s.ref.width, s.ref.height);
        }));
  }

  /// Keeps the last grabbed frame as a view; returns the view count.
  Future<int> add() {
    final a = _address;
    return Isolate.run(() {
      final n = bev_intr_add(Pointer.fromAddress(a));
      if (n < 0) throw CalibrationException(_lastError());
      return n;
    });
  }

  Future<IntrinsicsResult> calibrate() {
    final a = _address;
    return Isolate.run(() => using((arena) {
          final r = arena<BevIntrResult>();
          _check(bev_intr_calibrate(Pointer.fromAddress(a), r));
          final v = r.ref;
          return IntrinsicsResult(
            imageW: v.imageW,
            imageH: v.imageH,
            views: v.views,
            rmsPx: v.rmsPx,
            worstViewPx: v.worstViewPx,
            fx: v.fx,
            fy: v.fy,
            cx: v.cx,
            cy: v.cy,
            dist: [v.k1, v.k2, v.p1, v.p2, v.k3],
          );
        }));
  }

  void save(String lensIniPath) => _withString(lensIniPath, (p) => _check(bev_intr_save(_h, p)));

  /// Stops the camera; it can take a moment, so it runs off the UI isolate.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final a = _address;
    await Isolate.run(() => bev_intr_close(Pointer.fromAddress(a)));
  }
}
