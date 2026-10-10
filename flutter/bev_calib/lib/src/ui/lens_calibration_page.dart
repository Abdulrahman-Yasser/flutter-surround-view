import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../calibration.dart';
import '../paths.dart';

const _panel = Color(0xFF1B1B21);
const _good = Color(0xFF43C46B);
const _warn = Color(0xFFFFB224);
const _bad = Color(0xFFE5484D);

/// Lens calibration for one camera: hold the board at many poses, keep the
/// good frames, then fit and save `<lens_dir>/<lens>-lens.ini`.
class LensCalibrationPage extends StatefulWidget {
  const LensCalibrationPage({super.key, required this.paths, this.board = const BoardSpec()});

  final CalibPaths paths;
  final BoardSpec board;

  @override
  State<LensCalibrationPage> createState() => _LensCalibrationPageState();
}

class _LensCalibrationPageState extends State<LensCalibrationPage> {
  static const _recommendedViews = 15;

  List<CameraInfo>? _cameras;
  String? _cameraError;
  String? _camera;
  Map<CameraPosition, PositionState> _mounted = const {};
  final _lens = TextEditingController();
  // The name last filled in for the chosen camera; a name typed over it is kept.
  String _suggested = '';
  bool _fisheye = false;

  // Keep a view by itself once the board is well seen and somewhere new.
  static const _autoMinCorners = 18;
  bool _auto = true;
  IntrinsicsStatus? _lastKept;
  DateTime _lastKeptAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _keeping = false;
  String? _captureDir;
  late final _squares = TextEditingController(text: '${widget.board.squaresX}x${widget.board.squaresY}');
  late final _square = TextEditingController(text: (widget.board.squareLen * 1000).toStringAsFixed(0));
  late final _marker = TextEditingController(text: (widget.board.markerLen * 1000).toStringAsFixed(0));
  late final _dict = TextEditingController(text: widget.board.dict);

  IntrinsicsSession? _session;
  bool _running = false;
  Future<void>? _loop;
  Uint8List? _frame;
  IntrinsicsStatus? _status;
  IntrinsicsResult? _result;
  String? _busy;
  String? _error;

  String get _previewPath => '${widget.paths.workDir}/lens-preview.jpg';

  @override
  void initState() {
    super.initState();
    _mounted = PositionState.read(widget.paths.configPath);
    CameraInfo.list().then((cams) {
      if (!mounted) return;
      setState(() {
        _cameras = cams;
        _camera = cams.isEmpty ? null : cams.first.id;
        _suggestName();
      });
    }, onError: (Object e) {
      if (mounted) setState(() => _cameraError = '$e');
    });
  }

  @override
  void dispose() {
    _stop();
    for (final c in [_lens, _squares, _square, _marker, _dict]) {
      c.dispose();
    }
    super.dispose();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // Markers but no corners means the board fields don't describe the board
  // in view. A ChArUco board of c x r squares carries c*r/2 markers numbered
  // from its first id, so the highest id seen suggests sizes that would fit.
  String _mismatchHint(IntrinsicsStatus st) {
    final count = st.idMax + 1;
    final fits = <String>[
      for (var c = 3; c <= 12; c++)
        for (var r = 3; r <= c; r++)
          if (c * r ~/ 2 == count) '${c}x$r',
    ];
    return '${st.markers} markers (ids ${st.idMin}-${st.idMax}) seen but no corners: the board fields '
        'don\'t match the board in view.'
        '${fits.isEmpty ? '' : ' A board with $count markers is ${fits.join(' or ')} (columns x rows, either way round).'}';
  }

  String _cameraName(String id) {
    final model = _cameras?.firstWhere((c) => c.id == id, orElse: () => CameraInfo(id, id)).model ?? id;
    for (final e in _mounted.entries) {
      if (e.value.camera == id) return '$model · ${e.key.label}';
    }
    return model;
  }

  BoardSpec? _boardFromFields() {
    final sq = _squares.text.toLowerCase().split('x');
    final sx = sq.length == 2 ? int.tryParse(sq[0].trim()) : null;
    final sy = sq.length == 2 ? int.tryParse(sq[1].trim()) : null;
    final square = double.tryParse(_square.text);
    final marker = double.tryParse(_marker.text);
    if (sx == null || sy == null || square == null || marker == null || marker >= square) return null;
    return BoardSpec(
      dict: _dict.text.trim(),
      squaresX: sx,
      squaresY: sy,
      squareLen: square / 1000,
      markerLen: marker / 1000,
      legacy: widget.board.legacy,
    );
  }

  Future<void> _start() async {
    final board = _boardFromFields();
    if (board == null) {
      _toast('Check the board fields');
      return;
    }
    if (_lens.text.trim().isEmpty) {
      _toast('Name the lens, e.g. imx219');
      return;
    }
    setState(() {
      _busy = 'Opening ${_cameraName(_camera!)}';
      _error = null;
      _result = null;
    });
    try {
      await Directory(widget.paths.workDir).create(recursive: true);
      _session = await IntrinsicsSession.open(_camera!, board, fisheye: _fisheye);
      _lastKept = null;
      _captureDir = widget.paths.newCaptureDir('lens-${_lens.text.trim()}');
      if (_captureDir != null) {
        File('$_captureDir/board.ini').writeAsStringSync('# ${_cameraName(_camera!)}, ${_fisheye ? 'fisheye' : 'pinhole'}\n'
            '[camera]\nposition = front\n[board]\ndict = ${board.dict}\n'
            'squares = ${board.squaresX}x${board.squaresY}\nsquare = ${board.squareLen}\n'
            'marker = ${board.markerLen}\nlegacy = ${board.legacy ? 1 : 0}\n');
      }
      _running = true;
      _loop = _grabLoop();
    } on CalibrationException catch (e) {
      _error = e.message;
    }
    if (mounted) setState(() => _busy = null);
  }

  Future<void> _grabLoop() async {
    final s = _session!;
    while (_running) {
      try {
        final st = await s.grab(_previewPath);
        final bytes = await File(_previewPath).readAsBytes();
        if (!mounted || !_running) break;
        setState(() {
          _status = st;
          _frame = bytes;
        });
        if (_auto && _isNewView(st)) await _add();
      } on CalibrationException catch (e) {
        if (mounted) setState(() => _error = e.message);
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  Future<void> _stop() async {
    _running = false;
    final s = _session;
    _session = null;
    await _loop;
    await s?.close();
  }

  // Enough corners, a while since the last kept view, and the board moved or
  // came nearer or farther: a pose the fit doesn't have yet.
  bool _isNewView(IntrinsicsStatus st) {
    if (!st.usable || st.corners < _autoMinCorners || _keeping) return false;
    if (DateTime.now().difference(_lastKeptAt) < const Duration(milliseconds: 1500)) return false;
    final last = _lastKept;
    if (last == null) return true;
    final moved = (Offset(st.centerX, st.centerY) - Offset(last.centerX, last.centerY)).distance;
    final scaled = last.extent > 0 ? (st.extent / last.extent - 1).abs() : 1.0;
    return moved > 0.08 || scaled > 0.15;
  }

  Future<void> _add() async {
    final st = _status;
    _keeping = true;
    try {
      final n = await _session!.add();
      _lastKept = st;
      _lastKeptAt = DateTime.now();
      if (_captureDir != null) {
        await _session!.saveKept('$_captureDir/view_${n.toString().padLeft(2, '0')}.png');
      }
      if (mounted) setState(() => _status = IntrinsicsStatus(0, false, n, st?.width ?? 0, st?.height ?? 0));
    } on CalibrationException catch (e) {
      _toast('$e');
    } finally {
      _keeping = false;
    }
  }

  Future<void> _calibrate() async {
    setState(() => _busy = 'Fitting the lens model');
    try {
      final r = await _session!.calibrate();
      setState(() => _result = r);
    } on CalibrationException catch (e) {
      _toast('$e');
    }
    setState(() => _busy = null);
  }

  CameraPosition? _positionOf(String id) {
    for (final e in _mounted.entries) {
      if (e.value.camera == id) return e.key;
    }
    return null;
  }

  // One lens file per physical camera: its model and the port libcamera
  // names it by (imx219-i2c-88000), so the calibration stays with the camera
  // wherever it is mounted. /dev/video numbers aren't stable across boots.
  void _suggestName() {
    final id = _camera;
    if (id == null || (_lens.text.trim().isNotEmpty && _lens.text.trim() != _suggested)) return;
    String slug(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    final model = (_cameras?.firstWhere((c) => c.id == id, orElse: () => CameraInfo(id, 'camera')).model ?? 'camera')
        .split(':')
        .first;
    final parts = id.split('/').where((p) => p.isNotEmpty).toList();
    // A CSI sensor is a node (imx219@10) under its bus (i2c@88000); a USB
    // camera's last node is its port.
    final port = parts.isEmpty
        ? id
        : parts.last.startsWith('usb') || parts.length < 2
            ? parts.last.split(':').first
            : parts[parts.length - 2];
    _suggested = '${slug(model)}-${slug(port)}';
    _lens.text = _suggested;
  }

  Future<void> _save() async {
    final name = _lens.text.trim();
    final path = '${widget.paths.lensDir}/$name-lens.ini';
    if (File(path).existsSync()) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Replace $name-lens.ini?'),
          content: const Text('A lens file with this name exists, possibly from another camera. '
              'Give this one its own name to keep both.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Replace')),
          ],
        ),
      );
      if (replace != true || !mounted) return;
    }
    try {
      Directory(widget.paths.lensDir).createSync(recursive: true);
      _session!.save(path);
      final position = _camera == null ? null : _positionOf(_camera!);
      if (position != null) {
        PositionState.setLens(widget.paths.configPath, position, name);
        _mounted = PositionState.read(widget.paths.configPath);
        _toast('Saved $name-lens.ini, now the ${position.label} camera\'s lens');
      } else {
        _toast('Saved $path');
      }
    } on CalibrationException catch (e) {
      _toast('Save failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Lens calibration'), backgroundColor: _panel),
      body: SafeArea(
        child: Stack(children: [
          Positioned.fill(
            child: Row(children: [
              Expanded(
                child: ColoredBox(
                  color: Colors.black,
                  child: _frame == null
                      ? Center(
                          child: Text(_session == null ? 'Pick a camera and start' : 'Waiting for frames',
                              style: const TextStyle(color: Colors.white54)),
                        )
                      : Image.memory(_frame!, gaplessPlayback: true, fit: BoxFit.contain),
                ),
              ),
              SizedBox(width: 300, child: _panelContent()),
            ]),
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
        ]),
      ),
    );
  }

  Widget _field(String label, TextEditingController c, {bool enabled = true}) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: TextField(
          controller: c,
          enabled: enabled,
          decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
        ),
      );

  Widget _panelContent() {
    const small = TextStyle(color: Colors.white70, fontSize: 12);
    final live = _session != null;
    final st = _status;
    final views = st?.views ?? 0;
    final r = _result;
    return Container(
      color: _panel,
      padding: const EdgeInsets.all(12),
      child: ListView(children: [
        if (!live) ...[
          DropdownButtonFormField<String>(
            initialValue: _camera,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Camera', isDense: true, border: OutlineInputBorder()),
            items: [
              for (final c in _cameras ?? const <CameraInfo>[])
                DropdownMenuItem(value: c.id, child: Text(_cameraName(c.id), overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() {
              _camera = v;
              _suggestName();
            }),
          ),
          if (_cameras != null && _cameras!.isEmpty)
            const Text('No camera found', style: TextStyle(color: _bad, fontSize: 12)),
          if (_cameraError != null) Text(_cameraError!, style: const TextStyle(color: _bad, fontSize: 12)),
          const SizedBox(height: 6),
          _field('Lens name (file <name>-lens.ini)', _lens),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Pinhole')),
                ButtonSegment(value: true, label: Text('Fisheye')),
              ],
              selected: {_fisheye},
              onSelectionChanged: (v) => setState(() => _fisheye = v.first),
            ),
          ),
          _field('Board squares (cols x rows)', _squares),
          Row(children: [
            Expanded(child: _field('Square mm', _square)),
            const SizedBox(width: 6),
            Expanded(child: _field('Marker mm', _marker)),
          ]),
          _field('ArUco dictionary', _dict),
          FilledButton.icon(
              onPressed: _camera == null ? null : _start, icon: const Icon(Icons.play_arrow), label: const Text('Start')),
          if (_error != null) Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: const TextStyle(color: _bad, fontSize: 12)),
          ),
        ] else ...[
          Text('${_cameraName(_camera!)} · ${_lens.text.trim()} · ${_fisheye ? 'fisheye' : 'pinhole'}',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          if (st != null) ...[
            Text('${st.width}x${st.height}', style: small),
            const SizedBox(height: 6),
            Text(
              st.usable ? '${st.corners} corners, good' : (st.corners > 0 ? '${st.corners} corners, not enough spread' : 'Board not found'),
              style: TextStyle(color: st.usable ? _good : _warn, fontSize: 13),
            ),
            if (st.corners == 0 && st.markers >= 4)
              Text(_mismatchHint(st), style: const TextStyle(color: _bad, fontSize: 12)),
          ],
          const SizedBox(height: 6),
          LinearProgressIndicator(value: (views / _recommendedViews).clamp(0.0, 1.0)),
          Text('$views views kept (aim for $_recommendedViews+)', style: small),
          const SizedBox(height: 6),
          Text(
            'Fill the frame with different poses: near and far, tilted, and in every corner '
            'and edge. Orange dots show where earlier views covered.'
            '${_fisheye ? ' A fisheye needs the board right out at the rim too, or its edges stay unfit.' : ''}',
            style: small,
          ),
          const SizedBox(height: 10),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Auto capture', style: TextStyle(fontSize: 13)),
            subtitle: const Text('Keeps a view by itself at $_autoMinCorners+ corners in a new pose',
                style: TextStyle(fontSize: 11)),
            value: _auto,
            onChanged: (v) => setState(() => _auto = v),
          ),
          FilledButton.icon(
            onPressed: st?.usable == true && !_keeping ? _add : null,
            icon: const Icon(Icons.add_a_photo),
            label: const Text('Keep this view'),
          ),
          if (_captureDir != null)
            Text('Views saved in $_captureDir', style: const TextStyle(color: Colors.white38, fontSize: 11)),
          const SizedBox(height: 6),
          OutlinedButton(onPressed: views >= 3 ? _calibrate : null, child: const Text('Calibrate')),
          if (r != null) ...[
            const Divider(),
            Text('${r.views} views · rms ${r.rmsPx.toStringAsFixed(3)} px',
                style: TextStyle(color: r.rmsPx < 0.5 ? _good : (r.rmsPx < 1 ? _warn : _bad))),
            Text('worst view ${r.worstViewPx.toStringAsFixed(2)} px', style: small),
            Text('fx ${r.fx.toStringAsFixed(1)}  fy ${r.fy.toStringAsFixed(1)}', style: small),
            Text('cx ${r.cx.toStringAsFixed(1)}  cy ${r.cy.toStringAsFixed(1)}', style: small),
            if (r.fisheye) ...[
              Text('k1 ${r.dist[0].toStringAsFixed(4)}  k2 ${r.dist[1].toStringAsFixed(4)}', style: small),
              Text('k3 ${r.dist[2].toStringAsFixed(4)}  k4 ${r.dist[3].toStringAsFixed(4)}', style: small),
            ] else ...[
              Text('k1 ${r.dist[0].toStringAsFixed(4)}  k2 ${r.dist[1].toStringAsFixed(4)}  k3 ${r.dist[4].toStringAsFixed(4)}',
                  style: small),
              Text('p1 ${r.dist[2].toStringAsFixed(5)}  p2 ${r.dist[3].toStringAsFixed(5)}', style: small),
            ],
            const SizedBox(height: 6),
            FilledButton.icon(onPressed: _save, icon: const Icon(Icons.save), label: const Text('Save lens file')),
            Text('${widget.paths.lensDir}/${_lens.text.trim()}-lens.ini', style: small),
          ],
          const SizedBox(height: 10),
          TextButton(
            onPressed: () async {
              setState(() => _busy = 'Stopping camera');
              await _stop();
              if (mounted) {
                setState(() {
                  _busy = null;
                  _frame = null;
                  _status = null;
                });
              }
            },
            child: const Text('Stop camera'),
          ),
        ],
      ]),
    );
  }
}
