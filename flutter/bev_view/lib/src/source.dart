/// How the pipeline output is scaled into the view.
enum BevFit {
  /// Whole image, letterboxed or pillarboxed.
  contain,

  /// Fills the view, cropping the image.
  cover,

  /// Stretched to the view.
  fill,
}

/// The surround blend backends, as the CLI's `--blend`.
enum BevBlend { feather, coverage }

/// What a BevView renders.
///
/// Each source encodes to the native creation params (ihs/bev_params.h), which
/// mirror the CLI's flags -- so a command line that works is a source that
/// works. Paths are read by the process running the shell; prefix one with
/// `asset:` to resolve it inside the app's flutter_assets.
sealed class BevSource {
  const BevSource();

  /// `key=value` pairs, in order. Keys may repeat.
  List<MapEntry<String, String>> toParams();
}

/// The live libcamera path: one camera, NV12, through the red-tint + parking
/// grid shader.
final class BevCameraSource extends BevSource {
  const BevCameraSource({
    this.index = 0,
    this.cameraId,
    this.width,
    this.height,
    this.fps,
    this.tuningFile,
  });

  final int index;

  /// libcamera's id for the camera (Camera::id()); wins over [index].
  final String? cameraId;

  /// Requested stream size; libcamera may adjust it. Default 1640x1232.
  final int? width;
  final int? height;

  /// Pins the sensor's frame duration, capping the exposure auto-exposure may
  /// choose. Null leaves the duration to the IPA, which lengthens the frame to
  /// gather light — so the same scene streams slower in a dim room than a lit
  /// one, and two runs are no longer comparable. Set it when the rate matters
  /// more than the noise, as it does for a surround view.
  final double? fps;

  /// IPA tuning JSON, as `--tuning-file`. Process-wide: only the first camera
  /// view's value takes effect.
  final String? tuningFile;

  @override
  List<MapEntry<String, String>> toParams() => [
    const MapEntry('mode', 'camera'),
    if (cameraId != null) MapEntry('camera_id', cameraId!) else MapEntry('camera_index', '$index'),
    if (width != null) MapEntry('width', '$width'),
    if (height != null) MapEntry('height', '$height'),
    if (fps != null) MapEntry('camera_fps', '$fps'),
    if (tuningFile != null) MapEntry('tuning_file', tuningFile!),
  ];
}

/// The N-camera surround view, with per-slot calibration from a
/// bev_config.ini.
final class BevSurroundSource extends BevSource {
  /// Sources in config-slot order: `camera:<index>` or `position:<name>`.
  const BevSurroundSource(
    this.sources, {
    this.undistort,
    this.config = 'bev_config.ini',
    this.lensDir,
    this.blend = BevBlend.feather,
    this.pxPerMeter,
    this.fps,
    this.width,
    this.height,
  });

  final List<String> sources;

  /// One camera seen straight on instead of on the ground: its lens
  /// distortion removed and zoomed out by this factor (1 = the camera's own
  /// field, below 1 wider, as a fisheye needs). Needs no surround
  /// calibration.
  final double? undistort;

  final String config;

  /// Where `<lens_model>-lens.ini` files live; default the config's directory.
  final String? lensDir;
  final BevBlend blend;

  /// Overrides the config file's px_per_m.
  final double? pxPerMeter;

  /// Pins the sensors' frame rate, and the requested stream size (the same
  /// for every camera).
  final double? fps;
  final int? width;
  final int? height;

  @override
  List<MapEntry<String, String>> toParams() => [
    const MapEntry('mode', 'surround'),
    if (undistort != null) MapEntry('undistort', '$undistort'),
    if (fps != null) MapEntry('camera_fps', '$fps'),
    if (width != null) MapEntry('width', '$width'),
    if (height != null) MapEntry('height', '$height'),
    for (final src in sources) MapEntry('src', src),
    MapEntry('config', config),
    if (lensDir != null) MapEntry('lens_dir', lensDir!),
    MapEntry('blend', blend.name),
    if (pxPerMeter != null) MapEntry('px_per_m', '$pxPerMeter'),
  ];
}

/// Scrolling colour bars generated on the CPU -- for bringing a shell up with
/// no camera.
final class BevPatternSource extends BevSource {
  const BevPatternSource({
    this.width = 1280,
    this.height = 720,
    this.fps = 30,
  });

  final int width;
  final int height;

  /// Frames per second the pattern paces itself to. The cameras pace
  /// themselves; this one has no input to follow. 0 runs it flat out, which is how you
  /// measure what the view can carry on a board.
  final double fps;

  @override
  List<MapEntry<String, String>> toParams() => [
    const MapEntry('mode', 'pattern'),
    MapEntry('width', '$width'),
    MapEntry('height', '$height'),
    MapEntry('pattern_fps', '$fps'),
  ];
}

/// The creation-params text for a view of [source].
String encodeBevParams(
  BevSource source, {
  BevFit fit = BevFit.contain,
  int ringSize = 4,
  bool scanout = false,
}) {
  final lines = <String>[
    for (final entry in source.toParams()) '${entry.key}=${entry.value}',
    'fit=${fit.name}',
    'ring_size=$ringSize',
    if (scanout) 'scanout=1',
  ];
  for (final line in lines) {
    // One line per pair is the whole format; a newline in a value would split it.
    if (line.contains('\n')) {
      throw ArgumentError.value(line, 'source', 'values cannot contain newlines');
    }
  }
  return '${lines.join('\n')}\n';
}
