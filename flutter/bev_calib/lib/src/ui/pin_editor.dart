import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../calibration.dart';

const pinInlier = Color(0xFF43C46B);
const pinOutlier = Color(0xFFB66DFF);
const pinMoved = Color(0xFFFFB224);
const pinGuessed = Color(0xFFE5484D);

Color pinColor(CalibPointInfo p) =>
    p.guessed ? pinGuessed : (!p.inlier ? pinOutlier : (p.moved ? pinMoved : pinInlier));

/// How a pin is drawn: arms along the image axes, or diagonal.
enum PinMarker { plus, cross }

/// One pin: four arms with an open centre, so the corner pixel itself stays
/// visible, outlined to show on any background. The selected one is larger
/// and ringed. Shared by the image and the board picture so both match.
void paintPin(Canvas canvas, Offset at, Color color, PinMarker marker,
    {bool selected = false, double scale = 1}) {
  final dirs = marker == PinMarker.plus
      ? const [Offset(1, 0), Offset(-1, 0), Offset(0, 1), Offset(0, -1)]
      : const [Offset(0.7071, 0.7071), Offset(-0.7071, 0.7071), Offset(0.7071, -0.7071), Offset(-0.7071, -0.7071)];
  final arm = (selected ? 16.0 : 9.0) * scale, gap = (selected ? 4.0 : 3.0) * scale;
  void arms(Paint paint) {
    for (final d in dirs) {
      canvas.drawLine(at + d * gap, at + d * arm, paint);
    }
  }

  arms(Paint()
    ..color = Colors.black.withValues(alpha: 0.6)
    ..strokeWidth = selected ? 3.5 : 3);
  arms(Paint()
    ..color = color
    ..strokeWidth = selected ? 1.6 : 1.2);
  if (selected) {
    canvas.drawCircle(
        at,
        arm + 4 * scale,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
  }
}

/// A captured still with a pin on every corner. Scroll or pinch zooms,
/// dragging the background pans, double-click zooms in on the selected pin.
/// Tap selects the nearest pin and dragging one moves it, with a magnifier
/// when zoomed out. While [placing] is set, a tap reports where it landed
/// through [onPlace] instead. Edits are reported in still pixels.
class PinEditor extends StatefulWidget {
  const PinEditor({
    super.key,
    required this.image,
    required this.imageSize,
    required this.points,
    required this.selected,
    required this.onSelect,
    required this.onMoved,
    this.marker = PinMarker.plus,
    this.visible,
    this.placing,
    this.onPlace,
  });

  final File image;
  final Size imageSize;
  final List<CalibPointInfo> points;
  final int? selected;
  final ValueChanged<int?> onSelect;
  final void Function(int index, Offset imagePx) onMoved;
  final PinMarker marker;

  /// Which pins to draw and accept taps on; the selected one always is.
  final bool Function(CalibPointInfo p)? visible;

  /// Shown while waiting for the tap that places a corner by hand.
  final String? placing;
  final ValueChanged<Offset>? onPlace;

  @override
  State<PinEditor> createState() => _PinEditorState();
}

class _PinEditorState extends State<PinEditor> {
  static const _loupeSize = 150.0;
  static const _loupeLift = 130.0;
  static const _maxZoom = 40.0;

  int? _dragging;
  Offset? _dragImagePx;
  Offset? _finger;

  double _fit = 1;
  Offset _fitOrigin = Offset.zero;
  double _zoom = 1;
  Offset _pan = Offset.zero;
  Offset? _doubleTapAt;
  Offset? _lastFocal;
  double _lastScale = 1;
  Size _box = Size.zero;

  double get _scale => _fit * _zoom;
  Offset get _origin => _fitOrigin + _pan;
  Offset _toScreen(Offset img) => _origin + img * _scale;
  Offset _toImage(Offset screen) => (screen - _origin) / _scale;

  @override
  void didUpdateWidget(PinEditor old) {
    super.didUpdateWidget(old);
    if (old.image.path != widget.image.path) {
      _zoom = 1;
      _pan = Offset.zero;
      return;
    }
    // Picked elsewhere (the board picture, the arrows): bring it into view.
    final sel = widget.selected;
    if (sel != null && sel != old.selected && sel < widget.points.length && _zoom > 1) {
      final at = _toScreen(Offset(widget.points[sel].x, widget.points[sel].y));
      if (!(Offset.zero & _box).deflate(24).contains(at)) {
        _pan += _box.center(Offset.zero) - at;
      }
    }
  }

  bool _shown(CalibPointInfo p) => p.index == widget.selected || (widget.visible?.call(p) ?? true);

  int? _nearest(Offset screen, double radius) {
    int? best;
    var bestD = radius;
    for (final p in widget.points) {
      if (!_shown(p)) continue;
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

  void _zoomAt(Offset focal, double factor) {
    final img = _toImage(focal);
    setState(() {
      _zoom = (_zoom * factor).clamp(1.0, _maxZoom);
      _pan = focal - img * _scale - _fitOrigin;
      if (_zoom == 1) _pan = Offset.zero;
    });
  }

  void _zoomTo(Offset img, double zoom, Size box) {
    setState(() {
      _zoom = zoom.clamp(1.0, _maxZoom);
      _pan = _zoom == 1 ? Offset.zero : Offset(box.width / 2, box.height / 2) - img * _scale - _fitOrigin;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final iw = widget.imageSize.width, ih = widget.imageSize.height;
      final size = Size(box.maxWidth, box.maxHeight);
      _box = size;
      _fit = math.min(box.maxWidth / iw, box.maxHeight / ih);
      _fitOrigin = Offset((box.maxWidth - iw * _fit) / 2, (box.maxHeight - ih * _fit) / 2);

      final editor = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          if (widget.placing != null) {
            widget.onPlace?.call(_clampToImage(_toImage(d.localPosition)));
          } else {
            widget.onSelect(_nearest(d.localPosition, 32));
          }
        },
        onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
        onDoubleTap: () {
          final sel = widget.selected;
          final target = sel != null && sel < widget.points.length
              ? Offset(widget.points[sel].x, widget.points[sel].y)
              : _toImage(_doubleTapAt ?? size.center(Offset.zero));
          _zoomTo(target, _zoom < 4 ? 8 : 1, size);
        },
        onScaleStart: (d) {
          _lastFocal = d.localFocalPoint;
          _lastScale = 1;
          if (d.pointerCount != 1 || widget.placing != null) return;
          final sel = widget.selected;
          final onSelected = sel != null &&
              sel < widget.points.length &&
              (_toScreen(Offset(widget.points[sel].x, widget.points[sel].y)) - d.localFocalPoint).distance < 40;
          final idx = onSelected ? sel : _nearest(d.localFocalPoint, 24);
          if (idx == null) return;
          if (idx != sel) widget.onSelect(idx);
          final p = widget.points[idx];
          setState(() {
            _dragging = idx;
            _dragImagePx = Offset(p.x, p.y);
            _finger = d.localFocalPoint;
          });
        },
        onScaleUpdate: (d) {
          final delta = d.localFocalPoint - (_lastFocal ?? d.localFocalPoint);
          _lastFocal = d.localFocalPoint;
          if (_dragging != null) {
            setState(() {
              _dragImagePx = _clampToImage(_dragImagePx! + delta / _scale);
              _finger = d.localFocalPoint;
            });
            return;
          }
          if (d.scale != _lastScale) {
            _zoomAt(d.localFocalPoint, d.scale / _lastScale);
            _lastScale = d.scale;
          }
          if (_zoom > 1) setState(() => _pan += delta);
        },
        onScaleEnd: (_) => _endDrag(),
        child: ClipRect(
          child: Stack(
            children: [
              Positioned(
                left: _origin.dx,
                top: _origin.dy,
                width: iw * _scale,
                height: ih * _scale,
                child: Image.file(
                  widget.image,
                  fit: BoxFit.fill,
                  gaplessPlayback: true,
                  filterQuality: _scale > 1.5 ? FilterQuality.none : FilterQuality.medium,
                ),
              ),
              Positioned.fill(
                child: CustomPaint(
                  painter: _PinPainter(
                    points: [for (final p in widget.points) if (_shown(p)) p],
                    selected: widget.selected,
                    dragging: _dragging,
                    dragImagePx: _dragImagePx,
                    toScreen: _toScreen,
                    marker: widget.marker,
                  ),
                ),
              ),
              if (_dragging != null && _finger != null && _scale < 1) _loupe(),
              if (widget.placing != null)
                Positioned(left: 8, bottom: 8, child: _Badge(text: widget.placing!, color: pinMoved)),
              Positioned(
                right: 6,
                top: 6,
                child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  _ZoomButton(icon: Icons.add, onTap: () => _zoomAt(size.center(Offset.zero), 1.6)),
                  _ZoomButton(icon: Icons.remove, onTap: () => _zoomAt(size.center(Offset.zero), 1 / 1.6)),
                  _ZoomButton(icon: Icons.fit_screen, onTap: () => _zoomTo(Offset.zero, 1, size)),
                  if (_zoom > 1) _Badge(text: '${(_scale * 100).round()}%', color: Colors.white70),
                ]),
              ),
            ],
          ),
        ),
      );
      return Listener(
        onPointerSignal: (e) {
          if (e is PointerScrollEvent) _zoomAt(e.localPosition, e.scrollDelta.dy < 0 ? 1.25 : 1 / 1.25);
        },
        child: editor,
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

class _ZoomButton extends StatelessWidget {
  const _ZoomButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.all(6), child: Icon(icon, size: 18, color: Colors.white)),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(text, style: TextStyle(color: color, fontSize: 12)),
      ),
    );
  }
}

class _PinPainter extends CustomPainter {
  _PinPainter({
    required this.points,
    required this.selected,
    required this.dragging,
    required this.dragImagePx,
    required this.toScreen,
    required this.marker,
  });

  final List<CalibPointInfo> points;
  final int? selected, dragging;
  final Offset? dragImagePx;
  final Offset Function(Offset) toScreen;
  final PinMarker marker;

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in points) {
      final at = toScreen(p.index == dragging && dragImagePx != null ? dragImagePx! : Offset(p.x, p.y));
      paintPin(canvas, at, p.index == dragging ? pinMoved : pinColor(p), marker, selected: p.index == selected);
    }
  }

  @override
  bool shouldRepaint(_PinPainter old) => true;
}
