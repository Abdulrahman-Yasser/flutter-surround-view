/// ChArUco calibration for the surround-view pipeline.
///
/// [SurroundCalibrationPage] computes each camera's car-frame homography from
/// boards laid out around the car and writes them to bev_config.ini;
/// [LensCalibrationPage] fits a camera's lens model into `<lens>-lens.ini`.
/// Both drive libbev_calib.so, built by this package's hook. Never show them
/// while a bev_view view is live: the two cannot hold the cameras at once.
library;

export 'src/calibration.dart';
export 'src/paths.dart';
export 'src/ui/layout_diagram.dart' show LayoutDiagram;
export 'src/ui/lens_calibration_page.dart' show LensCalibrationPage;
export 'src/ui/pin_editor.dart' show PinEditor;
export 'src/ui/surround_calibration_page.dart' show SurroundCalibrationPage;
