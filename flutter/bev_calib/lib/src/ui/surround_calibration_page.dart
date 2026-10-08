import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

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
  Map<CameraPosition, PositionState> _mounted = const {};
  List<CameraInfo> _cameraList = const [];
  String? _captureDir;

  PinMarker _marker = PinMarker.plus;
  bool _showAll = true;
  bool _showMissing = true;
  int _refBoard = 0;
  int? _refCorner;
  ({int board, int corner})? _placing;
  String? _refKey;
  Uint8List? _refPng;
  ({double margin, double pxPerM})? _refMap;
  String? _refError;
  final Map<int, List<Offset>> _sheetCorners = {};

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
      final positions = PositionState.read(_paths.configPath);
      if (_paths.offlineImagesDir == null) {
        CameraInfo.list().then((cams) {
          if (mounted) setState(() => _cameraList = cams);
        }, onError: (Object _) {});
      }
      setState(() {
        _mounted = positions;
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
      _session = CalibrationSession.open(layout, lensDir: _paths.lensDir, configPath: _paths.configPath);
    } on CalibrationException catch (e) {
      _toast('Cannot open ${layout.name}: $e');
      return;
    }
    _captureDir = _paths.offlineImagesDir == null
        ? _paths.newCaptureDir('surround-${layout.path.split('/').last.replaceAll('.ini', '')}')
        : null;
    if (_captureDir != null) File(layout.path).copySync('$_captureDir/${layout.path.split('/').last}');
    setState(() {
      _cams = [for (var i = 0; i < layout.cameras.length; i++) _Cam(i)];
      _cam = 0;
      _selected = null;
      _refBoard = 0;
      _refCorner = null;
      _placing = null;
      _refKey = null;
      _sheetCorners.clear();
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
    final position = _layout!.cameras[i].position;
    setState(() {
      cam.error = null;
      cam.status = 'Capturing';
    });
    try {
      final offline = _paths.offlineImage(position.key);
      if (offline != null) {
        await _track(s.loadImage(i, offline));
      } else {
        await _track(s.capture(i));
        // Kept at full resolution for looking into this calibration later.
        if (_captureDir != null) await _track(s.saveImage(i, '$_captureDir/${position.key}.png'));
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

  Future<void> _setLens(int i, String lens) async {
    try {
      _session!.setLens(i, lens);
    } on CalibrationException catch (e) {
      _toast('$e');
      return;
    }
    await _redetect(i);
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

  void _select(int? i) {
    setState(() {
      _selected = i;
      _placing = null;
      final pts = _cams[_cam].points;
      if (i != null && i < pts.length) {
        _refBoard = pts[i].board;
        _refCorner = pts[i].corner;
      }
    });
  }

  void _place(Offset px) {
    final target = _placing;
    if (target == null) return;
    try {
      final idx = _session!.placePoint(_cam, target.board, target.corner, px.dx, px.dy);
      setState(() {
        _placing = null;
        _resolve(_cam);
        _selected = idx;
      });
    } on CalibrationException catch (e) {
      _toast('$e');
    }
  }

  void _findMissing() {
    try {
      final n = _session!.addMissing(_cam);
      setState(() {
        _showMissing = true;
        _resolve(_cam);
      });
      _toast(n == 0
          ? 'Every corner in view is already pinned'
          : '$n missing corners added as red pins; drag each onto its corner');
    } on CalibrationException catch (e) {
      _toast('$e. Place corners by hand from the board picture below.');
    }
  }

  // The board picture under the buttons, redrawn when the board or the
  // marked corner changes.
  void _updateReference() {
    final key = '$_refBoard';
    if (key == _refKey || _session == null) return;
    try {
      final path = '${_paths.workDir}/board-reference.png';
      _refMap = _session!.boardReference(_refBoard, -1, 512, path);
      _refPng = File(path).readAsBytesSync();
      _refError = null;
    } on Object catch (e) {
      _refPng = null;
      _refError = '$e';
    }
    _refKey = key;
  }

  void _tapReference(Offset local, double shownWidth) {
    final map = _refMap;
    if (map == null) return;
    final corners = _sheetCorners.putIfAbsent(_refBoard, () => _session!.boardCorners(_refBoard));
    final sheet = local / (shownWidth / 512) / map.pxPerM - Offset(map.margin, map.margin);
    final b = _layout!.boards[_refBoard];
    var best = -1;
    var bestD = b.square ? b.squareLen : 2 * b.squareLen;
    for (var i = 0; i < corners.length; i++) {
      final d = (corners[i] - sheet).distance;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    if (best < 0) return;
    final pts = _cams[_cam].points;
    final existing = pts.indexWhere((p) => p.board == _refBoard && p.corner == best);
    if (existing >= 0) {
      _select(existing);
    } else {
      setState(() {
        _selected = null;
        _refCorner = best;
        _placing = (board: _refBoard, corner: best);
      });
    }
  }

  // Where a board lies around the car, by the bearing of its centre: the
  // nearest of the eight camera positions.
  String _boardPlace(int i) {
    final b = _layout!.boards[i];
    final bearing = math.atan2(b.y, b.x) * 180 / math.pi;
    double off(CameraPosition p) => ((bearing - p.facingDeg + 540) % 360 - 180).abs();
    return CameraPosition.values.reduce((a, c) => off(c) < off(a) ? c : a).label;
  }

  // Numbered when several boards of one kind share a place.
  String _boardName(int i) {
    final b = _layout!.boards[i];
    final place = _boardPlace(i);
    final same = [
      for (var k = 0; k < _layout!.boards.length; k++)
        if (_layout!.boards[k].square == b.square && _boardPlace(k) == place) k,
    ];
    return same.length == 1 ? place : '$place ${same.indexOf(i) + 1}';
  }

  String _boardLabel(int i) {
    final b = _layout!.boards[i];
    return b.square
        ? 'Board $i · ${_boardName(i)} · black square'
        : 'Board $i · ${_boardName(i)} · ${b.squaresX}x${b.squaresY} · ids ${b.firstId}-${b.firstId + b.squaresX * b.squaresY ~/ 2 - 1}';
  }

  // The boards this camera can see: within 85 degrees of where it faces,
  // from where it is mounted, plus any it actually found corners on.
  List<int> _cameraBoards(int cam) {
    final l = _layout!;
    final c = l.cameras[cam];
    final mount = Offset(c.position.mountX * l.carWidth / 2, c.position.mountY * l.carLength / 2);
    final rad = c.facingDeg * math.pi / 180;
    final facing = Offset(math.cos(rad), math.sin(rad));
    final found = {for (final p in _cams[cam].points) if (!p.guessed) p.board};
    return [
      for (var i = 0; i < l.boards.length; i++)
        if (found.contains(i) ||
            () {
              final to = Offset(l.boards[i].x, l.boards[i].y) - mount;
              final cos = (to.dx * facing.dx + to.dy * facing.dy) / math.max(to.distance, 1e-9);
              return cos >= math.cos(85 * math.pi / 180);
            }())
          i,
    ];
  }

  Widget _referencePanel(_Cam cam) {
    const small = TextStyle(color: Colors.white70, fontSize: 12);
    final boards = _cameraBoards(cam.index);
    if (boards.isEmpty) return const Text('No board of this layout is in front of this camera.', style: small);
    if (!boards.contains(_refBoard)) {
      _refBoard = boards.first;
      _refCorner = null;
      _placing = null;
    }
    _updateReference();
    final corner = _refCorner;
    final pinIdx = corner == null
        ? -1
        : cam.points.indexWhere((p) => p.board == _refBoard && p.corner == corner);
    final pin = pinIdx >= 0 ? cam.points[pinIdx] : null;
    final status = corner == null
        ? 'Click a corner on the board to find or place it.'
        : pin == null
            ? 'Corner $corner: not pinned. Click where it is in the image.'
            : 'Corner $corner: ${pin.guessed ? 'not found yet (red pin), drag it into place' : pin.moved ? 'moved by hand' : pin.inlier ? 'detected' : 'outlier'}';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Where is this corner?', style: TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      DropdownButton<int>(
        value: _refBoard,
        isExpanded: true,
        isDense: true,
        items: [
          for (final i in boards)
            DropdownMenuItem(value: i, child: Text(_boardLabel(i), style: const TextStyle(fontSize: 12))),
        ],
        onChanged: (v) => setState(() {
          _refBoard = v ?? 0;
          _refCorner = null;
          _placing = null;
        }),
      ),
      const SizedBox(height: 4),
      if (_refPng != null)
        LayoutBuilder(
          builder: (context, box) => GestureDetector(
            onTapUp: (d) => _tapReference(d.localPosition, box.maxWidth),
            child: Stack(children: [
              Image.memory(_refPng!, width: box.maxWidth, gaplessPlayback: true),
              Positioned.fill(
                child: CustomPaint(
                  painter: _ReferencePainter(
                    corners: _sheetCorners.putIfAbsent(_refBoard, () => _session!.boardCorners(_refBoard)),
                    toPx: (sheet) => (sheet + Offset(_refMap!.margin, _refMap!.margin)) *
                        _refMap!.pxPerM *
                        (box.maxWidth / 512),
                    pins: {
                      for (final p in cam.points)
                        if (p.board == _refBoard) p.corner: p,
                    },
                    selected: _refCorner,
                    marker: _marker,
                    square: _layout!.boards[_refBoard].square,
                  ),
                ),
              ),
            ]),
          ),
        ),
      if (_refError != null) Text(_refError!, style: const TextStyle(color: _bad, fontSize: 12)),
      const SizedBox(height: 4),
      Text(status, style: small),
      if (_placing != null)
        TextButton(onPressed: () => setState(() => _placing = null), child: const Text('Cancel placing')),
    ]);
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
    return 'Camera ${i + 1} · ${c.position.label}';
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
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text(
                  'Place the boards as drawn, thick edge = printed top. Keep them still '
                  'until every camera is captured.',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                if (_layout != null) _positionsLine(_layout!),
                Text('Board positions: ${_paths.layoutsDir}',
                    style: const TextStyle(color: Colors.white38, fontSize: 11)),
              ]),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: _layout == null || (_paths.offlineImagesDir == null && _unmounted(_layout!).isNotEmpty)
                  ? null
                  : _start,
              icon: const Icon(Icons.camera_alt),
              label: const Text('Capture'),
            ),
          ]),
        ),
      ],
    );
  }

  List<CameraPosition> _unmounted(CalibLayout l) => [
        for (final c in l.cameras)
          if (!(_mounted[c.position]?.assigned ?? false)) c.position,
      ];

  // Model name, plus the port when another connected camera is the same model.
  String _cameraName(CameraInfo c) {
    final twin = _cameraList.where((o) => o.model == c.model).length > 1;
    if (!twin) return c.model;
    final parts = c.id.split('/');
    return '${c.model} · ${parts.length > 1 ? parts[parts.length - 2] : c.id}';
  }

  void _assign(CameraPosition p, String id) {
    try {
      PositionState.assign(_paths.configPath, p, id);
      setState(() => _mounted = PositionState.read(_paths.configPath));
    } on CalibrationException catch (e) {
      _toast('$e');
    }
  }

  // Which connected camera is at each position the layout needs, set right
  // here; it is the same assignment Settings > Cameras makes.
  Widget _positionsLine(CalibLayout l) {
    if (_paths.offlineImagesDir != null) {
      return Text('Cameras: ${l.cameras.map((c) => c.position.label).join(', ')} (from saved stills)',
          style: const TextStyle(color: Colors.white70, fontSize: 12));
    }
    final missing = _unmounted(l);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 10, runSpacing: 4, children: [
        for (final c in l.cameras)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text('${c.position.label}: ', style: const TextStyle(color: Colors.white70, fontSize: 12)),
            DropdownButton<String>(
              value: _cameraList.any((k) => k.id == _mounted[c.position]?.camera)
                  ? _mounted[c.position]!.camera
                  : null,
              hint: Text(_mounted[c.position]?.assigned ?? false ? 'not connected' : 'choose camera',
                  style: const TextStyle(color: _warn, fontSize: 12)),
              isDense: true,
              items: [
                for (final k in _cameraList)
                  DropdownMenuItem(value: k.id, child: Text(_cameraName(k), style: const TextStyle(fontSize: 12))),
              ],
              onChanged: (id) {
                if (id != null) _assign(c.position, id);
              },
            ),
          ]),
      ]),
      if (missing.isNotEmpty)
        Text('Choose a camera for ${missing.map((p) => p.label).join(', ')}.',
            style: const TextStyle(color: _warn, fontSize: 12)),
    ]);
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
            onSelect: _select,
            onMoved: _move,
            marker: _marker,
            visible: (p) => _showAll && (_showMissing || !p.guessed),
            placing: _placing == null
                ? null
                : 'Click where board ${_placing!.board}, corner ${_placing!.corner} is',
            onPlace: _place,
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
    final outliers = cam.points.where((p) => !p.inlier && !p.guessed).length;
    final guessed = cam.points.where((p) => p.guessed).length;
    final lenses = LensFile.list(_paths.lensDir);
    final lens = _session!.lenses[_cam];
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
            DropdownButtonFormField<String>(
              key: ValueKey('lens$_cam'),
              initialValue: lens,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Lens', isDense: true, border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem(value: '', child: Text('None (no undistortion)')),
                for (final l in lenses)
                  DropdownMenuItem(value: l.name, child: Text('${l.name} · ${l.fisheye ? 'fisheye' : 'pinhole'}')),
                if (lens.isNotEmpty && !lenses.any((l) => l.name == lens))
                  DropdownMenuItem(value: lens, child: Text('$lens (no file yet)')),
              ],
              onChanged: (v) => _setLens(_cam, v ?? ''),
            ),
            const SizedBox(height: 6),
            if (!_session!.hasLens(_cam))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  lens.isEmpty
                      ? 'No lens for this camera, so corners are used without undistortion.'
                      : 'No lens file for "$lens" yet, so corners are used without undistortion. '
                          'Run lens calibration first for the best result.',
                  style: const TextStyle(color: _warn, fontSize: 12),
                ),
              ),
            Text('${cam.points.length} corners · ${s.inliers} inliers · $outliers outliers', style: small),
            if (guessed > 0)
              Text('$guessed corners not found yet: drag each red pin onto its corner',
                  style: const TextStyle(color: _warn, fontSize: 12)),
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
              _Legend(pinGuessed, 'not found'),
            ]),
            const Divider(),
            if (sel == null)
              const Text(
                  'Tap a pin to select it, drag it onto the corner where two black squares meet, '
                  'or onto the corner of a black square.',
                  style: small)
            else ...[
              Text(
                  'Board ${sel.board} · corner ${sel.corner} · '
                  '${sel.guessed ? 'not found' : sel.moved ? 'moved' : (sel.inlier ? 'ok' : 'outlier')}',
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
                onPressed: outliers + guessed == 0 ? null : () => _stepPoint(1, outliersOnly: true),
                child: const Text('Next outlier'),
              ),
            ]),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: () => _redetect(_cam), child: const Text('Re-detect'))),
              const SizedBox(width: 6),
              Expanded(child: OutlinedButton(onPressed: () => _retake(_cam), child: const Text('Retake'))),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              SegmentedButton<PinMarker>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(value: PinMarker.plus, label: Text('+')),
                  ButtonSegment(value: PinMarker.cross, label: Text('×')),
                ],
                selected: {_marker},
                onSelectionChanged: (v) => setState(() => _marker = v.first),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: FilterChip(
                  label: const Text('All pins', style: TextStyle(fontSize: 12)),
                  selected: _showAll,
                  onSelected: (v) => setState(() => _showAll = v),
                ),
              ),
            ]),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: _findMissing, child: const Text('Find missing'))),
              const SizedBox(width: 6),
              FilterChip(
                label: const Text('Not found', style: TextStyle(fontSize: 12)),
                selected: _showMissing,
                onSelected: (v) => setState(() => _showMissing = v),
              ),
            ]),
            const Divider(),
            _referencePanel(cam),
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

/// The camera's pins on the printed board: each corner in its pin's colour,
/// a faint ring where a corner has no pin yet, the selected one as in the
/// image.
class _ReferencePainter extends CustomPainter {
  _ReferencePainter({
    required this.corners,
    required this.toPx,
    required this.pins,
    required this.selected,
    required this.marker,
    required this.square,
  });

  final List<Offset> corners;
  final Offset Function(Offset sheet) toPx;
  final Map<int, CalibPointInfo> pins;
  final int? selected;
  final PinMarker marker;
  final bool square;

  @override
  void paint(Canvas canvas, Size size) {
    // A square's four corners sit far apart on plain black, so they get
    // full-size pins and their numbers outside the square.
    final scale = square ? 1.1 : 0.7;
    final middle = corners.isEmpty
        ? Offset.zero
        : toPx(corners.reduce((a, b) => a + b) / corners.length.toDouble());
    for (var i = 0; i < corners.length; i++) {
      final at = toPx(corners[i]);
      if (square) {
        final out = at - middle;
        final label = TextPainter(
          text: TextSpan(text: '$i', style: const TextStyle(color: Colors.black87, fontSize: 12, fontWeight: FontWeight.w700)),
          textDirection: TextDirection.ltr,
        )..layout();
        final pos = at + out / out.distance * 18 - Offset(label.width / 2, label.height / 2);
        label.paint(canvas, pos);
      }
      if (i == selected) continue;
      final pin = pins[i];
      if (pin == null) {
        canvas.drawCircle(
            at,
            square ? 6 : 3.5,
            Paint()
              ..color = Colors.blueGrey
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5);
      } else {
        paintPin(canvas, at, pinColor(pin), marker, scale: scale);
      }
    }
    final sel = selected;
    if (sel != null && sel < corners.length) {
      final pin = pins[sel];
      paintPin(canvas, toPx(corners[sel]), pin == null ? pinMoved : pinColor(pin), marker,
          selected: true, scale: square ? 1.0 : 0.8);
    }
  }

  @override
  bool shouldRepaint(_ReferencePainter old) => true;
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
