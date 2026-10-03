import 'dart:io';

import 'package:bev_calib/bev_calib.dart';
import 'package:bev_view/bev_view.dart';

// Shared with the calibration screens, so the view reads what they save.
final CalibPaths calibPaths = CalibPaths.fromEnvironment();

BevSource surroundSourceFromEnvironment() {
  final Map<String, String> env = Platform.environment;
  String? get(String key) {
    final String? value = env[key];
    return value == null || value.isEmpty ? null : value;
  }

  final int cameras = int.tryParse(get('BEV_CAMERAS') ?? '') ?? 2;
  return BevSurroundSource(
    <String>[for (int i = 0; i < cameras; i++) 'camera:$i'],
    config: calibPaths.configPath,
    lensDir: calibPaths.lensDir,
    pxPerMeter: double.tryParse(get('BEV_PX_PER_M') ?? ''),
    fps: double.tryParse(get('BEV_CAM_FPS') ?? '') ?? 30,
    width: int.tryParse(get('BEV_WIDTH') ?? ''),
    height: int.tryParse(get('BEV_HEIGHT') ?? ''),
  );
}

BevSource cameraSourceFromEnvironment(int index) {
  final Map<String, String> env = Platform.environment;
  return BevCameraSource(
    index: index,
    fps: double.tryParse(env['BEV_CAM_FPS'] ?? '') ?? 30,
    width: int.tryParse(env['BEV_WIDTH'] ?? ''),
    height: int.tryParse(env['BEV_HEIGHT'] ?? ''),
  );
}

BevSource birdsEyeSourceFromEnvironment(int index) {
  final Map<String, String> env = Platform.environment;
  String? get(String key) {
    final String? value = env[key];
    return value == null || value.isEmpty ? null : value;
  }

  return BevSurroundSource(
    <String>['camera:$index'],
    config: calibPaths.configPath,
    lensDir: calibPaths.lensDir,
    pxPerMeter: double.tryParse(get('BEV_PX_PER_M') ?? ''),
    fps: double.tryParse(get('BEV_CAM_FPS') ?? '') ?? 30,
    width: int.tryParse(get('BEV_WIDTH') ?? ''),
    height: int.tryParse(get('BEV_HEIGHT') ?? ''),
  );
}
