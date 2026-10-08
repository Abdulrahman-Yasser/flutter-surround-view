import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../calibration.dart';

const pinInlier = Color(0xFF43C46B);
const pinOutlier = Color(0xFFE5484D);
const pinMoved = Color(0xFFFFB224);
const pinGuessed = Color(0xFF9AA0A6);

Color pinColor(CalibPointInfo p) =>
    p.guessed ? pinGuessed : (!p.inlier ? pinOutlier : (p.moved ? pinMoved : pinInlier));

/// A captured still with a pin on every detected corner. Tap selects the
/// nearest pin; dragging moves it with a magnifier above the finger. Edits
/// are reported in still pixels when the finger lifts.
class PinEditor extends StatefulWidget {
  const PinEditor({
    super.key,
    required this.image,
    required this.imageSize,
    required this.points,
    required this.selected,
    required this.onSelect,
    required this.onMoved,
  });

  final File image;
  final Size imageSize;
  final List<CalibPointInfo> points;
  final int? selected;
  final ValueChanged<int?> onSelect;
  final void Function(int index, Offset imagePx) onMoved;

  @override
  State<PinEditor> createState() => _PinEditorState();
}

class _PinEditorState extends State<PinEditor> {
  static const _loupeSize = 150.0;
  static const _loupeLift = 130.0;

  int? _dragging;
  Offset? _dragImagePx;
  Offset? _finger;

  double _scale = 1;
  Offset _origin = Offset.zero;

  Offset _toScreen(Offset img) => _origin + img * _scale;

  int? _nearest(Offset screen, double radius) {
    int? best;
    var bestD = radius;
    for (final p in widget.points) {
      final d = (_toScreen(Offset(p.x, p.y)) - screen).distance;
      if (d < bestD) {
        bestD = d;
        best = p.index;
      }
    }
    return best;
  }

  Offset _clampToImage(Offset img) => Offset(
        img.dx.clamp(0.0, widget.imageSize.width - 1),
        img.dy.clamp(0.0, widget.imageSize.height - 1),
      );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final iw = widget.imageSize.width, ih = widget.imageSize.height;
      _scale = math.min(box.maxWidth / iw, box.maxHeight / ih);
      _origin = Offset((box.maxWidth - iw * _scale) / 2, (box.maxHeight - ih * _scale) / 2);

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => widget.onSelect(_nearest(d.localPosition, 32)),
        onPanStart: (d) {
          final sel = widget.selected;
          final onSelected = sel != null &&
              sel < widget.points.length &&
              (_toScreen(Offset(widget.points[sel].x, widget.points[sel].y)) - d.localPosition).distance < 40;
          final idx = onSelected ? sel : _nearest(d.localPosition, 40);
          if (idx == null) return;
          if (idx != sel) widget.onSelect(idx);
          final p = widget.points[idx];
          setState(() {
            _dragging = idx;
            _dragImagePx = Offset(p.x, p.y);
            _finger = d.localPosition;
          });
        },
        onPanUpdate: (d) {
          if (_dragging == null) return;
          setState(() {
            _dragImagePx = _clampToImage(_dragImagePx! + d.delta / _scale);
            _finger = d.localPosition;
          });
        },
        onPanEnd: (_) => _endDrag(),
        onPanCancel: _endDrag,
        child: Stack(
          children: [
            Positioned(
              left: _origin.dx,
              top: _origin.dy,
              width: iw * _scale,
              height: ih * _scale,
              child: Image.file(widget.image, fit: BoxFit.fill, gaplessPlayback: true),
            ),
            Positioned.fill(
              child: CustomPaint(
                painter: _PinPainter(
                  points: widget.points,
                  selected: widget.selected,
                  dragging: _dragging,
                  dragImagePx: _dragImagePx,
                  toScreen: _toScreen,
                ),
              ),
            ),
            if (_dragging != null && _finger != null) _loupe(),
          ],
        ),
      );
    });
  }

  // Sits above the finger so it isn't covered by it, looking at the pin.
  Widget _loupe() {
    final center = Offset(_finger!.dx, math.max(_loupeSize / 2, _finger!.dy - _loupeLift));
    return Positioned(
      left: center.dx - _loupeSize / 2,
      top: center.dy - _loupeSize / 2,
      child: RawMagnifier(
        size: const Size(_loupeSize, _loupeSize),
        magnificationScale: 3,
        focalPointOffset: _toScreen(_dragImagePx!) - center,
        decoration: const MagnifierDecoration(
          shape: CircleBorder(side: BorderSide(color: Colors.white, width: 2)),
        ),
      ),
    );
  }

  void _endDrag() {
    final idx = _dragging, pos = _dragImagePx;
    setState(() {
      _dragging = null;
      _dragImagePx = null;
      _finger = null;
    });
    if (idx != null && pos != null) widget.onMoved(idx, pos);
  }
}

class _PinPainter extends CustomPainter {
  _PinPainter({
    required this.points,
    required this.selected,
    required this.dragging,
    required this.dragImagePx,
    required this.toScreen,
  });

  final List<CalibPointInfo> points;
  final int? selected, dragging;
  final Offset? dragImagePx;
  final Offset Function(Offset) toScreen;

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in points) {
      final isSel = p.index == selected;
      final at = toScreen(p.index == dragging && dragImagePx != null ? dragImagePx! : Offset(p.x, p.y));
      final color = p.index == dragging ? pinMoved : pinColor(p);
      final r = isSel ? 9.0 : 6.0;
      final stroke = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = isSel ? 2 : 1.5;
      canvas.drawCircle(at, r, stroke);
      final arm = r + 5;
      final thin = Paint()
        ..color = color
        ..strokeWidth = 1;
      canvas.drawLine(at - Offset(arm, 0), at - Offset(r * 0.4, 0), thin);
      canvas.drawLine(at + Offset(r * 0.4, 0), at + Offset(arm, 0), thin);
      canvas.drawLine(at - Offset(0, arm), at - Offset(0, r * 0.4), thin);
      canvas.drawLine(at + Offset(0, r * 0.4), at + Offset(0, arm), thin);
      if (isSel) {
        canvas.drawCircle(
            at,
            r + 4,
            Paint()
              ..color = Colors.white
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5);
      }
    }
  }

  @override
  bool shouldRepaint(_PinPainter old) => true;
}
