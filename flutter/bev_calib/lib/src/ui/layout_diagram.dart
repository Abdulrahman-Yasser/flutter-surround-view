import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../calibration.dart';

/// Top-down sketch of a layout: the car, its cameras, and where each board
/// goes, front up. The thick edge of a board is its printed top.
class LayoutDiagram extends StatelessWidget {
  const LayoutDiagram({super.key, required this.layout, this.highlightCamera});

  final CalibLayout layout;
  final int? highlightCamera;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _LayoutPainter(layout, highlightCamera),
      child: const SizedBox.expand(),
    );
  }
}

const _cameraColor = Color(0xFF3D7EFF);
const _boardColor = Color(0xFFE0E0E0);

class _LayoutPainter extends CustomPainter {
  _LayoutPainter(this.layout, this.highlight);

  final CalibLayout layout;
  final int? highlight;

  List<Offset> _boardCorners(LayoutBoard b) {
    final c = math.cos(b.yawDeg * math.pi / 180), s = math.sin(b.yawDeg * math.pi / 180);
    return [
      for (final (u, v) in [
        (-b.width / 2, b.height / 2),
        (b.width / 2, b.height / 2),
        (b.width / 2, -b.height / 2),
        (-b.width / 2, -b.height / 2),
      ])
        Offset(b.x + u * c - v * s, b.y + u * s + v * c),
    ];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final hw = layout.carWidth / 2, hl = layout.carLength / 2;
    var minX = -hw, maxX = hw, minY = -hl, maxY = hl;
    for (final b in layout.boards) {
      for (final p in _boardCorners(b)) {
        minX = math.min(minX, p.dx);
        maxX = math.max(maxX, p.dx);
        minY = math.min(minY, p.dy);
        maxY = math.max(maxY, p.dy);
      }
    }
    const margin = 0.4;
    minX -= margin;
    maxX += margin;
    minY -= margin;
    maxY += margin;
    final scale = math.min(size.width / (maxX - minX), size.height / (maxY - minY));
    final ox = (size.width - (maxX - minX) * scale) / 2, oy = (size.height - (maxY - minY) * scale) / 2;
    Offset px(double x, double y) => Offset(ox + (x - minX) * scale, oy + (maxY - y) * scale);

    final car = Rect.fromPoints(px(-hw, hl), px(hw, -hl));
    canvas.drawRRect(RRect.fromRectAndRadius(car, Radius.circular(car.width * 0.18)),
        Paint()..color = const Color(0xFF2A2A33));
    canvas.drawRRect(
        RRect.fromRectAndRadius(car, Radius.circular(car.width * 0.18)),
        Paint()
          ..color = Colors.white38
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
    final nose = Path()
      ..moveTo(car.center.dx, car.top + car.height * 0.08)
      ..lineTo(car.center.dx - car.width * 0.18, car.top + car.height * 0.2)
      ..lineTo(car.center.dx + car.width * 0.18, car.top + car.height * 0.2)
      ..close();
    canvas.drawPath(nose, Paint()..color = Colors.white24);

    for (final b in layout.boards) {
      final c = _boardCorners(b).map((p) => px(p.dx, p.dy)).toList();
      final path = Path()..addPolygon(c, true);
      if (b.square) {
        canvas.drawPath(path, Paint()..color = Colors.black);
        canvas.drawPath(
            path,
            Paint()
              ..color = _boardColor
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1);
        _label(canvas, 'square', (c[0] + c[2]) / 2, 10);
        continue;
      }
      canvas.drawPath(path, Paint()..color = _boardColor.withValues(alpha: 0.25));
      canvas.drawPath(
          path,
          Paint()
            ..color = _boardColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1);
      canvas.drawLine(c[0], c[1], Paint()
        ..color = _boardColor
        ..strokeWidth = 3);
      _label(canvas, 'id ${b.firstId}', (c[0] + c[2]) / 2, 10);
    }

    for (var i = 0; i < layout.cameras.length; i++) {
      final cam = layout.cameras[i];
      final rad = cam.facingDeg * math.pi / 180;
      final dir = Offset(math.cos(rad), math.sin(rad));
      final p = Offset(cam.position.mountX * hw, cam.position.mountY * hl);
      final from = px(p.dx, p.dy);
      final to = px(p.dx + dir.dx * 0.5, p.dy + dir.dy * 0.5);
      final selected = highlight == null || highlight == i;
      final paint = Paint()
        ..color = selected ? _cameraColor : _cameraColor.withValues(alpha: 0.3)
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(from, to, paint);
      canvas.drawCircle(from, 5, paint);
      _label(canvas, cam.position.short, from, 11, color: Colors.white);
    }
  }

  void _label(Canvas canvas, String text, Offset at, double size, {Color color = Colors.white70}) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: size, fontWeight: FontWeight.w600)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_LayoutPainter old) => old.layout != layout || old.highlight != highlight;
}
