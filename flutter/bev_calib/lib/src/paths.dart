import 'dart:io';

import 'package:flutter/services.dart';

/// Where calibration reads and writes. The live view must use the same
/// [configPath] and [lensDir] to pick up a saved calibration.
class CalibPaths {
  const CalibPaths({
    required this.configPath,
    required this.lensDir,
    required this.layoutsDir,
    required this.workDir,
    this.offlineImagesDir,
  });

  final String configPath;
  final String lensDir;
  final String layoutsDir;

  /// Scratch space for stills and previews.
  final String workDir;

  /// When set, stills are read from `<dir>/<position>.png` (or .jpg) instead of
  /// the cameras, so the screens can be exercised without hardware.
  final String? offlineImagesDir;

  /// BEV_CONFIG / BEV_LENS_DIR / BEV_CALIB_LAYOUTS / BEV_CALIB_IMAGES override.
  /// Otherwise a bev_config.ini in the working directory wins (running from a
  /// bundle directory), else everything lives in the per-user data directory
  /// (BEV_DATA_DIR, default ~/.config/surround_view): an installed app's
  /// working directory isn't writable.
  factory CalibPaths.fromEnvironment() {
    final env = Platform.environment;
    String? get(String k) => (env[k]?.isEmpty ?? true) ? null : env[k];

    final xdg = get('XDG_CONFIG_HOME') ?? '${get('HOME') ?? '/tmp'}/.config';
    final dataDir = get('BEV_DATA_DIR') ?? '$xdg/surround_view';
    final local = File('bev_config.ini');
    final configPath =
        get('BEV_CONFIG') ?? (local.existsSync() ? local.absolute.path : '$dataDir/bev_config.ini');
    final slash = configPath.lastIndexOf('/');
    return CalibPaths(
      configPath: configPath,
      lensDir: get('BEV_LENS_DIR') ?? (slash < 0 ? '.' : configPath.substring(0, slash)),
      layoutsDir: get('BEV_CALIB_LAYOUTS') ?? '$dataDir/layouts',
      workDir: '${Directory.systemTemp.path}/bev_calib',
      offlineImagesDir: get('BEV_CALIB_IMAGES'),
    );
  }

  /// Copies the bundled preset layouts into [layoutsDir], never overwriting
  /// one that is already there (it may hold measured board positions).
  Future<void> installDefaultLayouts() async {
    await Directory(layoutsDir).create(recursive: true);
    await Directory(lensDir).create(recursive: true);
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    for (final asset in manifest.listAssets()) {
      if (!asset.startsWith('packages/bev_calib/layouts/') || !asset.endsWith('.ini')) continue;
      final out = File('$layoutsDir/${asset.split('/').last}');
      // Presets from before camera positions number their cameras by slot,
      // which would now land them on the wrong positions.
      if (out.existsSync() && !RegExp(r'^\s*slot\s*=', multiLine: true).hasMatch(out.readAsStringSync())) {
        continue;
      }
      await out.writeAsString(await rootBundle.loadString(asset));
    }
  }

  /// `<offline dir>/<position>.png` (or .jpg), e.g. front_left.png.
  String? offlineImage(String position) {
    final dir = offlineImagesDir;
    if (dir == null) return null;
    for (final ext in ['png', 'jpg', 'jpeg']) {
      final f = File('$dir/$position.$ext');
      if (f.existsSync()) return f.path;
    }
    return null;
  }
}
