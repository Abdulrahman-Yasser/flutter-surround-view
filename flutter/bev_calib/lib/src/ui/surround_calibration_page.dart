import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../calibration.dart';
import '../paths.dart';
import 'layout_diagram.dart';
import 'pin_editor.dart';

const _accent = Color(0xFF3D7EFF);
const _panel = Color(0xFF1B1B21);
const _good = Color(0xFF43C46B);
const _warn = Color(0xFFFFB224);
const _bad = Color(0xFFE5484D);

Color _mmColor(double mm) => mm < 3 ? _good : (mm < 8 ? _warn : _bad);

enum _Step { pick, capture, review, result }

class _Cam {
  _Cam(this.index);

  final int index;
  String? status;
  String? error;
  File? image;
  Size? size;
  List<CalibPointInfo> points = const [];
  SolveResult solve = SolveResult.none;
  int generation = 0;
}

/// Surround calibration: pick a layout, capture every camera, check and
/// correct the detected board corners, then save the homographies.
/// Pops with true once a calibration was saved.
class SurroundCalibrationPage extends StatefulWidget {
  const SurroundCalibrationPage({super.key, required this.paths});

  final CalibPaths paths;

  @override
  State<SurroundCalibrationPage> createState() => _SurroundCalibrationPageState();
}

class _SurroundCalibrationPageState extends State<SurroundCalibrationPage> {
  _Step _step = _Step.pick;
  List<CalibLayout>? _layouts;
  String? _layoutError;
  CalibLayout? _layout;
  CalibrationSession? _session;
  List<_Cam> _cams = [];
  int _cam = 0;
  int? _selected;
  String? _busy;
  Future<void>? _inflight;
  File? _preview;
  int _previewGen = 0;
  List<SeamResult> _seams = const [];

  CalibPaths get _paths => widget.paths;

  @override
  void initState() {
    super.initState();
    _loadLayouts();
  }

  @override
  void dispose() {
    final s = _session;
    // A background call may still be using the session.
    if (s != null) (_inflight ?? Future<void>.value()).whenComplete(s.close);
    super.dispose();
  }

  Future<void> _loadLayouts() async {
    try {
      await _paths.installDefaultLayouts();
      await Directory(_paths.workDir).create(recursive: true);
      final all = CalibLayout.loadAll(_paths.layoutsDir);
      setState(() {
        _layouts = all;
        _layout ??= all.isEmpty ? null : all.first;
      });
    } catch (e) {
      setState(() => _layoutError = '$e');
    }
  }

  Future<T> _track<T>(Future<T> f) {
    _inflight = f.then((_) {}, onError: (_) {});
    return f;
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _start() async {
    final layout = _layout;
    if (layout == null) return;
    _session?.close();
    try {
      _session = CalibrationSession.open(layout, lensDir: _paths.lensDir);
    } on CalibrationException catch (e) {
      _toast('Cannot open ${layout.name}: $e');
      return;
    }
    setState(() {
      _cams = [for (var i = 0; i < layout.cameras.length; i++) _Cam(i)];
      _cam = 0;
      _selected = null;
      _step = _Step.capture;
    });
    for (var i = 0; i < _cams.length; i++) {
      if (!mounted) return;
      await _capture(i);
    }
    if (mounted && _cams.any((c) => c.image != null)) {
      setState(() {
        _cam = _cams.indexWhere((c) => c.image != null);
        _step = _Step.review;
      });
    }
  }

  Future<void> _capture(int i) async {
    final s = _session!;
    final cam = _cams[i];
    final slot = _layout!.cameras[i].slot;
    setState(() {
      cam.error = null;
      cam.status = 'Capturing';
    });
    try {
      final offline = _paths.offlineImage(slot);
      if (offline != null) {
        await _track(s.loadImage(i, offline));
      } else {
        await _track(s.capture(i));
      }
      if (!mounted) return;
      setState(() => cam.status = 'Finding corners');
      await _track(s.detect(i));
      final old = cam.image;
      final f = File('${_paths.workDir}/cam$i-${++cam.generation}.jpg');
      await _track(s.saveImage(i, f.path));
      if (old != null && old.existsSync()) old.deleteSync();
      final (w, h) = s.imageSize(i);
      cam.image = f;
      cam.size = Size(w.toDouble(), h.toDouble());
      _resolve(i);
    } on CalibrationException catch (e) {
      cam.error = e.message;
    }
    cam.status = null;
    if (mounted) setState(() {});
  }

  void _resolve(int i) {
    final s = _session!;
    _cams[i].solve = s.solve(i);
    _cams[i].points = s.points(i);
  }

  Future<void> _redetect(int i) async {
    setState(() => _busy = 'Finding corners');
    try {
      await _track(_session!.detect(i));
      _resolve(i);
    } on CalibrationException catch (e) {
      _toast('$e');
    }
    setState(() {
      _busy = null;
      _selected = null;
    });
  }

  Future<void> _retake(int i) async {
    setState(() => _busy = 'Capturing camera ${i + 1}');
    await _capture(i);
    setState(() {
      _busy = null;
      _selected = null;
    });
  }

  void _move(int index, Offset px) {
    final s = _session!;
    try {
      s.movePoint(_cam, index, px.dx, px.dy);
    } on CalibrationException catch (e) {
      _toast('$e');
      return;
    }
    setState(() => _resolve(_cam));
  }

  void _nudge(double dx, double dy) {
    final sel = _selected;
    if (sel == null) return;
    final p = _cams[_cam].points[sel];
    _move(sel, Offset(p.x + dx, p.y + dy));
  }

  void _stepPoint(int dir, {bool outliersOnly = false}) {
    final pts = _cams[_cam].points;
    if (pts.isEmpty) return;
    var i = _selected ?? (dir > 0 ? -1 : 0);
    for (var n = 0; n < pts.length; n++) {
      i = (i + dir) % pts.length;
      if (i < 0) i += pts.length;
      if (!outliersOnly || !pts[i].inlier) {
        setState(() => _selected = i);
        return;
      }
    }
    if (outliersOnly) _toast('No outliers left on this camera');
  }

  Future<void> _nextCamera() async {
    for (var i = _cam + 1; i < _cams.length; i++) {
      if (_cams[i].image != null) {
        setState(() {
          _cam = i;
          _selected = null;
        });
        return;
      }
    }
    await _finish();
  }

  Future<void> _finish() async {
    setState(() => _busy = 'Stitching preview');
    final f = File('${_paths.workDir}/preview-${++_previewGen}.jpg');
    try {
      await _track(_session!.renderPreview(f.path));
      final old = _preview;
      if (old != null && old.existsSync()) old.deleteSync();
      _preview = f;
      _seams = _session!.seams();
      _step = _Step.result;
    } on CalibrationException catch (e) {
      _toast('$e');
    }
    setState(() => _busy = null);
  }

  void _save() {
    try {
      _session!.saveConfig(_paths.configPath);
    } on CalibrationException catch (e) {
      _toast('Save failed: $e');
      return;
    }
    Navigator.of(context).pop(true);
  }

  String _camTitle(int i) {
    final c = _layout!.cameras[i];
    return 'Camera ${i + 1} · slot ${c.slot} · ${c.facingLabel}';
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (_step) {
      _Step.pick => 'Surround calibration',
      _Step.capture => 'Capturing · ${_layout?.name ?? ''}',
      _Step.review => 'Check corners · ${_camTitle(_cam)}',
      _Step.result => 'Result · ${_layout?.name ?? ''}',
    };
    return Scaffold(
      appBar: AppBar(title: Text(title), backgroundColor: _panel),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: switch (_step) {
                _Step.pick => _buildPick(),
                _Step.capture => _buildCapture(),
                _Step.review => _buildReview(),
                _Step.result => _buildResult(),
              },
            ),
            if (_busy != null)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black54,
                  child: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 12),
                      Text(_busy!),
                    ]),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPick() {
    final layouts = _layouts;
    if (_layoutError != null) return Center(child: Text(_layoutError!));
    if (layouts == null) return const Center(child: CircularProgressIndicator());
    if (layouts.isEmpty) {
      return Center(child: Text('No layouts in ${_paths.layoutsDir}'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [for (final l in layouts) _layoutCard(l)],
            ),
          ),
        ),
        Container(
          color: _panel,
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(
              child: Text(
                'Place the boards as drawn, thick edge = printed top. Keep them still '
                'until every camera is captured.\nBoard positions: ${_paths.layoutsDir}',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: _layout == null ? null : _start,
              icon: const Icon(Icons.camera_alt),
              label: const Text('Capture'),
            ),
          ]),
        ),
      ],
    );
  }

  Widget _layoutCard(CalibLayout l) {
    final selected = l.path == _layout?.path;
    return GestureDetector(
      onTap: () => setState(() => _layout = l),
      child: Container(
        width: 210,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: _panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? _accent : Colors.white12, width: selected ? 2 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(height: 200, child: LayoutDiagram(layout: l)),
          const SizedBox(height: 6),
          Text(l.name, style: const TextStyle(fontWeight: FontWeight.w700)),
          Text(
            '${l.cameras.length} camera${l.cameras.length == 1 ? '' : 's'} · '
            '${l.boards.length} board${l.boards.length == 1 ? '' : 's'}',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ]),
      ),
    );
  }

  Widget _buildCapture() {
    return Center(
      child: Container(
        width: 420,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(10)),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final c in _cams)
            ListTile(
              dense: true,
              leading: c.status != null
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(
                      c.error != null ? Icons.error : (c.image != null ? Icons.check_circle : Icons.schedule),
                      color: c.error != null ? _bad : (c.image != null ? _good : Colors.white38),
                    ),
              title: Text(_camTitle(c.index)),
              subtitle: Text(c.status ?? c.error ?? (c.image != null ? '${c.points.length} corners' : 'Waiting')),
            ),
          if (_cams.every((c) => c.status == null) && _cams.every((c) => c.image == null)) ...[
            const SizedBox(height: 8),
            FilledButton(onPressed: _start, child: const Text('Try again')),
          ],
        ]),
      ),
    );
  }

  Widget _buildReview() {
    final cam = _cams[_cam];
    final editor = cam.image == null
        ? Center(child: Text(cam.error ?? 'No image', style: const TextStyle(color: _bad)))
        : PinEditor(
            image: cam.image!,
            imageSize: cam.size!,
            points: cam.points,
            selected: _selected,
            onSelect: (i) => setState(() => _selected = i),
            onMoved: _move,
          );
    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < 760;
      final panel = _reviewPanel(cam);
      return narrow
          ? Column(children: [Expanded(child: editor), SizedBox(height: 230, child: panel)])
          : Row(children: [Expanded(child: editor), SizedBox(width: 280, child: panel)]);
    });
  }

  Widget _reviewPanel(_Cam cam) {
    final s = cam.solve;
    final sel = _selected == null || _selected! >= cam.points.length ? null : cam.points[_selected!];
    final last = _cams.lastIndexWhere((c) => c.image != null) == _cam;
    final edited = cam.points.any((p) => p.moved);
    final outliers = cam.points.where((p) => !p.inlier).length;
    const small = TextStyle(color: Colors.white70, fontSize: 12);

    return Container(
      color: _panel,
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: ListView(children: [
            Wrap(spacing: 4, runSpacing: 4, children: [
              for (final c in _cams)
                ChoiceChip(
                  showCheckmark: false,
                  label: Text('${c.index + 1}'),
                  selected: c.index == _cam,
                  avatar: Icon(Icons.circle,
                      size: 10, color: c.solve.ok ? _mmColor(c.solve.groundRmsMm) : _bad),
                  onSelected: c.image == null
                      ? null
                      : (_) => setState(() {
                            _cam = c.index;
                            _selected = null;
                          }),
                ),
            ]),
            const SizedBox(height: 8),
            if (!_session!.hasLens(_cam))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _layout!.cameras[_cam].lens.isEmpty
                      ? 'This layout names no lens for this camera, so corners are used without '
                          'undistortion.'
                      : 'No lens file for "${_layout!.cameras[_cam].lens}" yet, so corners are used '
                          'without undistortion. Run lens calibration first for the best result.',
                  style: const TextStyle(color: _warn, fontSize: 12),
                ),
              ),
            Text('${cam.points.length} corners · ${s.inliers} inliers · $outliers outliers', style: small),
            if (s.ok) ...[
              Text('Reprojection ${s.rmsPx.toStringAsFixed(2)} px (max ${s.maxPx.toStringAsFixed(1)})',
                  style: small),
              Text('Ground error ${s.groundRmsMm.toStringAsFixed(1)} mm (max ${s.groundMaxMm.toStringAsFixed(1)})',
                  style: small.copyWith(color: _mmColor(s.groundRmsMm))),
            ] else
              const Text('Not enough corners to solve this camera', style: TextStyle(color: _bad, fontSize: 12)),
            const SizedBox(height: 6),
            const Wrap(spacing: 10, children: [
              _Legend(pinInlier, 'ok'),
              _Legend(pinOutlier, 'outlier'),
              _Legend(pinMoved, 'moved, ok'),
            ]),
            const Divider(),
            if (sel == null)
              const Text('Tap a pin to select it, drag it onto the corner where two black squares meet.',
                  style: small)
            else ...[
              Text('Board ${sel.board} · corner ${sel.corner} · ${sel.moved ? 'moved' : (sel.inlier ? 'ok' : 'outlier')}',
                  style: small),
              const SizedBox(height: 6),
              _NudgePad(onNudge: _nudge),
            ],
            const SizedBox(height: 6),
            Row(children: [
              IconButton(onPressed: () => _stepPoint(-1), icon: const Icon(Icons.chevron_left), tooltip: 'Previous pin'),
              IconButton(onPressed: () => _stepPoint(1), icon: const Icon(Icons.chevron_right), tooltip: 'Next pin'),
              const Spacer(),
              TextButton(
                onPressed: outliers == 0 ? null : () => _stepPoint(1, outliersOnly: true),
                child: const Text('Next outlier'),
              ),
            ]),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: () => _redetect(_cam), child: const Text('Re-detect'))),
              const SizedBox(width: 6),
              Expanded(child: OutlinedButton(onPressed: () => _retake(_cam), child: const Text('Retake'))),
            ]),
          ]),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _nextCamera,
          child: Text(last ? (edited ? 'Finish' : 'Skip and finish') : (edited ? 'Next camera' : 'Skip')),
        ),
      ]),
    );
  }

  Widget _buildResult() {
    const small = TextStyle(color: Colors.white70, fontSize: 12);
    final failed = _cams.where((c) => !c.solve.ok).toList();
    return Row(children: [
      Expanded(
        child: _preview == null
            ? const SizedBox()
            : InteractiveViewer(maxScale: 8, child: Center(child: Image.file(_preview!))),
      ),
      Container(
        width: 300,
        color: _panel,
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: ListView(children: [
              const Text('Cameras', style: TextStyle(fontWeight: FontWeight.w700)),
              for (final c in _cams)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.circle, size: 12, color: c.solve.ok ? _mmColor(c.solve.groundRmsMm) : _bad),
                  title: Text(_camTitle(c.index)),
                  subtitle: Text(
                    c.solve.ok
                        ? 'ground ${c.solve.groundRmsMm.toStringAsFixed(1)} mm · ${c.solve.inliers} corners'
                        : 'not calibrated, keeps its old values',
                    style: small,
                  ),
                ),
              const SizedBox(height: 8),
              const Text('Seams', style: TextStyle(fontWeight: FontWeight.w700)),
              if (_seams.isEmpty)
                const Text('No two cameras share board corners, so the seams are not measured.', style: small),
              for (final m in _seams)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.circle, size: 12, color: _mmColor(m.medianMm)),
                  title: Text('Camera ${m.camA + 1} / ${m.camB + 1}'),
                  subtitle: Text(
                      'median ${m.medianMm.toStringAsFixed(1)} mm · max ${m.maxMm.toStringAsFixed(1)} mm · '
                      '${m.shared} shared corners',
                      style: small),
                ),
              if (failed.length == _cams.length)
                const Text('No camera could be solved.', style: TextStyle(color: _bad)),
              const SizedBox(height: 8),
              Text('Saves to ${_paths.configPath}', style: small),
            ]),
          ),
          FilledButton.icon(
            onPressed: failed.length == _cams.length ? null : _save,
            icon: const Icon(Icons.save),
            label: const Text('Save calibration'),
          ),
          const SizedBox(height: 6),
          OutlinedButton(
            onPressed: () => setState(() {
              _step = _Step.review;
              _cam = _cams.indexWhere((c) => c.image != null).clamp(0, _cams.length - 1);
            }),
            child: const Text('Back to corners'),
          ),
          const SizedBox(height: 6),
          TextButton(onPressed: () => setState(() => _step = _Step.pick), child: const Text('Start over')),
        ]),
      ),
    ]);
  }
}

class _Legend extends StatelessWidget {
  const _Legend(this.color, this.label);

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.circle_outlined, size: 12, color: color),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 11, color: Colors.white60)),
    ]);
  }
}

/// Moves the selected pin by single still pixels.
class _NudgePad extends StatelessWidget {
  const _NudgePad({required this.onNudge});

  final void Function(double dx, double dy) onNudge;

  @override
  Widget build(BuildContext context) {
    Widget b(IconData icon, double dx, double dy) => IconButton.filledTonal(
          onPressed: () => onNudge(dx, dy),
          icon: Icon(icon, size: 18),
          visualDensity: VisualDensity.compact,
        );
    return Column(children: [
      b(Icons.keyboard_arrow_up, 0, -1),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        b(Icons.keyboard_arrow_left, -1, 0),
        const SizedBox(width: 40),
        b(Icons.keyboard_arrow_right, 1, 0),
      ]),
      b(Icons.keyboard_arrow_down, 0, 1),
    ]);
  }
}
