import 'dart:io';

import 'package:bev_calib/bev_calib.dart';
import 'package:bev_view/bev_view.dart';

// Shared with the calibration screens, so the view reads what they save.
final CalibPaths calibPaths = CalibPaths.fromEnvironment();

String? _env(String key) {
  final String? value = Platform.environment[key];
  return value == null || value.isEmpty ? null : value;
}

/// Where each camera is mounted, from bev_config.ini. Empty if it can't be
/// read, which shows as no cameras rather than a crash.
Map<CameraPosition, PositionState> readMountedCameras() {
  try {
    return PositionState.read(calibPaths.configPath);
  } on Object {
    return const <CameraPosition, PositionState>{};
  }
}

/// Every mounted, calibrated camera stitched together; null if there is none.
BevSource? surroundSource(Map<CameraPosition, PositionState> mounted) {
  final List<String> sources = <String>[
    for (final CameraPosition p in CameraPosition.compass)
      if ((mounted[p]?.assigned ?? false) && mounted[p]!.calibrated) 'position:${p.key}',
  ];
  if (sources.isEmpty) return null;
  return _surround(sources);
}

BevSource cameraSource(String cameraId) {
  return BevCameraSource(
    cameraId: cameraId,
    fps: double.tryParse(_env('BEV_CAM_FPS') ?? '') ?? 30,
    width: int.tryParse(_env('BEV_WIDTH') ?? ''),
    height: int.tryParse(_env('BEV_HEIGHT') ?? ''),
  );
}

BevSource birdsEyeSource(CameraPosition position) => _surround(<String>['position:${position.key}']);

/// The camera with its fisheye distortion removed, zoomed out so most of its
/// field still fits a rectilinear picture.
BevSource flatSource(CameraPosition position) =>
    _surround(<String>['position:${position.key}'], undistort: 0.6);

/// Whether the camera at [position] has a fisheye lens file.
bool isFisheye(PositionState? state) {
  if (state == null || state.lens.isEmpty) return false;
  for (final LensFile l in LensFile.list(calibPaths.lensDir)) {
    if (l.name == state.lens) return l.fisheye;
  }
  return false;
}

BevSource _surround(List<String> sources, {double? undistort}) {
  return BevSurroundSource(
    sources,
    undistort: undistort,
    config: calibPaths.configPath,
    lensDir: calibPaths.lensDir,
    pxPerMeter: double.tryParse(_env('BEV_PX_PER_M') ?? ''),
    fps: double.tryParse(_env('BEV_CAM_FPS') ?? '') ?? 30,
    width: int.tryParse(_env('BEV_WIDTH') ?? ''),
    height: int.tryParse(_env('BEV_HEIGHT') ?? ''),
  );
}
