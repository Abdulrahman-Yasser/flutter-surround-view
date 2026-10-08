import 'package:bev_calib/bev_calib.dart';
import 'package:flutter/material.dart';

import 'bev_source.dart';
import 'live_camera_view.dart';
import 'models.dart';
import 'surround_view.dart';

class CameraViewport extends StatelessWidget {
  const CameraViewport({
    super.key,
    required this.mode,
    required this.position,
    required this.mounted,
    required this.overlays,
    required this.camSubViews,
    this.frontRearCamera = CameraPosition.front,
  });

  final ViewMode mode;
  final CameraPosition position;
  final Map<CameraPosition, PositionState> mounted;
  final Set<CameraOverlay> overlays;
  final CameraPosition frontRearCamera;
  final Map<CameraPosition, CameraSubView> camSubViews;

  Widget _single(CameraPosition p) =>
      SingleCameraView(position: p, state: mounted[p], subView: camSubViews[p]!, showLabel: true);

  @override
  Widget build(BuildContext context) {
    final Widget content = switch (mode) {
      ViewMode.surround360 => SurroundView(source: surroundSource(mounted)),
      ViewMode.sideViews => Row(
          children: <Widget>[
            Expanded(child: _single(CameraPosition.left)),
            Expanded(child: _single(CameraPosition.right)),
          ],
        ),
      ViewMode.frontRear => _single(frontRearCamera),
      ViewMode.camera => _single(position),
    };

    final bool showOverlays = mode != ViewMode.surround360;

    return ColoredBox(
      color: const Color(0xFF0A0A0C),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          content,
          if (showOverlays && overlays.contains(CameraOverlay.distanceGrid))
            const IgnorePointer(
              child: CustomPaint(painter: _DistanceGridPainter()),
            ),
          if (showOverlays && overlays.contains(CameraOverlay.guidelines))
            const IgnorePointer(
              child: CustomPaint(painter: _GuidelinesPainter()),
            ),
        ],
      ),
    );
  }
}

class SingleCameraView extends StatelessWidget {
  const SingleCameraView({
    super.key,
    required this.position,
    required this.state,
    required this.subView,
    this.showLabel = false,
  });

  final CameraPosition position;
  final PositionState? state;
  final CameraSubView subView;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final PositionState? s = state;
    if (s == null || !s.assigned) {
      return _Notice(position: position, text: 'No camera mounted here.\nSettings > Cameras.');
    }
    return switch (subView) {
      CameraSubView.normal =>
        LiveCameraView(position: position, cameraId: s.camera, birdsEye: false, showLabel: showLabel),
      CameraSubView.bev when s.calibrated =>
        LiveCameraView(position: position, cameraId: s.camera, birdsEye: true, showLabel: showLabel),
      CameraSubView.bev =>
        _Notice(position: position, text: 'Not calibrated yet.\nSettings > Surround calibration.'),
      // A fisheye flattened; a normal lens has nothing to flatten.
      CameraSubView.calibrated2d => LiveCameraView(
          position: position, cameraId: s.camera, birdsEye: false, flat: isFisheye(s), showLabel: showLabel),
    };
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.position, required this.text});

  final CameraPosition position;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFF14141A),
        border: Border.all(color: Colors.white12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.videocam_off, size: 40, color: Colors.white24),
            const SizedBox(height: 6),
            Text(
              '${position.label}\n$text',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// The right-hand panel next to a single camera: where the mounted cameras
/// are around the car.
class BevPlaceholder extends StatelessWidget {
  const BevPlaceholder({super.key, required this.mounted});

  final Map<CameraPosition, PositionState> mounted;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340, maxHeight: 460),
        child: AspectRatio(
          aspectRatio: 3 / 4,
          child: Stack(
            children: <Widget>[
              const Center(child: Icon(Icons.directions_car, size: 56, color: Colors.white24)),
              for (final CameraPosition p in CameraPosition.values)
                Align(
                  alignment: Alignment(p.mountX, -p.mountY),
                  child: _Badge(position: p, used: mounted[p]?.assigned ?? false),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.position, required this.used});

  final CameraPosition position;
  final bool used;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: used ? const Color(0xFF3D7EFF) : Colors.white10,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        position.short,
        style: TextStyle(color: used ? Colors.white : Colors.white30, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _GuidelinesPainter extends CustomPainter {
  const _GuidelinesPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;

    final Offset lNear = Offset(w * 0.30, h * 0.98);
    final Offset rNear = Offset(w * 0.70, h * 0.98);
    final Offset lFar = Offset(w * 0.43, h * 0.55);
    final Offset rFar = Offset(w * 0.57, h * 0.55);

    final Paint rail = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    canvas.drawLine(lNear, lFar, rail);
    canvas.drawLine(rNear, rFar, rail);

    void bar(double t, Color color) {
      final Paint p = Paint()
        ..color = color
        ..strokeWidth = 5;
      canvas.drawLine(
        Offset.lerp(lNear, lFar, t)!,
        Offset.lerp(rNear, rFar, t)!,
        p,
      );
    }

    bar(0.10, const Color(0xFFE53935));
    bar(0.45, const Color(0xFFFFB300));
    bar(0.82, const Color(0xFF43A047));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _DistanceGridPainter extends CustomPainter {
  const _DistanceGridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;

    for (final double f in <double>[0.55, 0.68, 0.80, 0.92]) {
      canvas.drawLine(
        Offset(size.width * 0.15, size.height * f),
        Offset(size.width * 0.85, size.height * f),
        p,
      );
    }
    canvas.drawLine(
      Offset(size.width * 0.30, size.height * 0.55),
      Offset(size.width * 0.12, size.height * 0.98),
      p,
    );
    canvas.drawLine(
      Offset(size.width * 0.70, size.height * 0.55),
      Offset(size.width * 0.88, size.height * 0.98),
      p,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
