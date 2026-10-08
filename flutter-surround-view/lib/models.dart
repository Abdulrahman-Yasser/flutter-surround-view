enum ViewMode {
  surround360,
  camera,
  sideViews,
  frontRear;
}

enum CameraSubView {
  normal,
  calibrated2d,
  bev;

  String get label => switch (this) {
        CameraSubView.normal => 'Normal (360°)',
        CameraSubView.calibrated2d => 'Calibrated 2D',
        CameraSubView.bev => 'BEV',
      };

  String get shortLabel => switch (this) {
        CameraSubView.normal => '360°',
        CameraSubView.calibrated2d => '2D',
        CameraSubView.bev => 'BEV',
      };

  CameraSubView get next => switch (this) {
        CameraSubView.normal => CameraSubView.calibrated2d,
        CameraSubView.calibrated2d => CameraSubView.bev,
        CameraSubView.bev => CameraSubView.normal,
      };
}

enum CameraOverlay { guidelines, distanceGrid }
