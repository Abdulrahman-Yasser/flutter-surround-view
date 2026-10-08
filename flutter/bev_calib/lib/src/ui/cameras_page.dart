import 'dart:io';

import 'package:flutter/material.dart';

import '../calibration.dart';
import '../paths.dart';

const _panel = Color(0xFF1B1B21);
const _good = Color(0xFF43C46B);
const _bad = Color(0xFFE5484D);

/// Says where each connected camera is mounted on the car, one camera per
/// position. Saves to bev_config.ini as soon as a position is picked. Pops
/// true if anything changed.
class CamerasPage extends StatefulWidget {
  const CamerasPage({super.key, required this.paths});

  final CalibPaths paths;

  @override
  State<CamerasPage> createState() => _CamerasPageState();
}

class _CamerasPageState extends State<CamerasPage> {
  List<CameraInfo>? _cameras;
  String? _error;
  Map<CameraPosition, PositionState> _mounted = const {};
  final Map<String, File> _shots = {};
  final Set<String> _shooting = {};
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _mounted = PositionState.read(widget.paths.configPath);
      final cams = await CameraInfo.list();
      if (!mounted) return;
      setState(() => _cameras = cams);
      await Directory(widget.paths.workDir).create(recursive: true);
      for (final c in cams) {
        await _snapshot(c);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _snapshot(CameraInfo c) async {
    setState(() => _shooting.add(c.id));
    final file = File('${widget.paths.workDir}/camera-${_cameras!.indexOf(c)}.jpg');
    try {
      await CameraInfo.snapshot(c.id, file.path);
      await FileImage(file).evict();
      if (mounted) setState(() => _shots[c.id] = file);
    } catch (e) {
      if (mounted) _toast('${c.model}: $e');
    }
    if (mounted) setState(() => _shooting.remove(c.id));
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  CameraPosition? _positionOf(String id) {
    for (final e in _mounted.entries) {
      if (e.value.camera == id) return e.key;
    }
    return null;
  }

  String _modelOf(String id) =>
      _cameras?.firstWhere((c) => c.id == id, orElse: () => CameraInfo(id, 'not connected')).model ?? id;

  void _assign(String id, CameraPosition? position) {
    try {
      final current = _positionOf(id);
      if (position == null) {
        if (current != null) PositionState.assign(widget.paths.configPath, current, '');
      } else {
        PositionState.assign(widget.paths.configPath, position, id);
      }
      setState(() {
        _mounted = PositionState.read(widget.paths.configPath);
        _changed = true;
      });
    } on CalibrationException catch (e) {
      _toast('$e');
    }
  }

  void _unmount(CameraPosition position) {
    try {
      PositionState.assign(widget.paths.configPath, position, '');
      setState(() {
        _mounted = PositionState.read(widget.paths.configPath);
        _changed = true;
      });
    } on CalibrationException catch (e) {
      _toast('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Cameras'), backgroundColor: _panel),
        body: SafeArea(child: _body()),
      ),
    );
  }

  Widget _body() {
    if (_error != null) return Center(child: Text(_error!, style: const TextStyle(color: _bad)));
    final cams = _cameras;
    if (cams == null) return const Center(child: CircularProgressIndicator());
    final missing = [
      for (final e in _mounted.entries)
        if (e.value.assigned && !cams.any((c) => c.id == e.value.camera)) e,
    ];
    return LayoutBuilder(builder: (context, box) {
      final list = ListView(padding: const EdgeInsets.all(12), children: [
        if (cams.isEmpty) const Text('No camera found', style: TextStyle(color: _bad)),
        for (final c in cams) _cameraCard(c),
        for (final e in missing)
          Card(
            color: _panel,
            child: ListTile(
              leading: const Icon(Icons.videocam_off, color: _bad),
              title: Text('${e.key.label}: camera not connected'),
              subtitle: Text(e.value.camera, style: const TextStyle(fontSize: 11)),
              trailing: TextButton(onPressed: () => _unmount(e.key), child: const Text('Clear')),
            ),
          ),
      ]);
      final grid = Padding(padding: const EdgeInsets.all(12), child: _positionGrid());
      return box.maxWidth > 760
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: list),
              SizedBox(width: 340, child: grid),
            ])
          : ListView(children: [grid, SizedBox(height: box.maxHeight, child: list)]);
    });
  }

  Widget _cameraCard(CameraInfo c) {
    final shot = _shots[c.id];
    final position = _positionOf(c.id);
    return Card(
      color: _panel,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          GestureDetector(
            onTap: _shooting.contains(c.id) ? null : () => _snapshot(c),
            child: Container(
              width: 200,
              height: 150,
              color: Colors.black,
              alignment: Alignment.center,
              child: _shooting.contains(c.id)
                  ? const CircularProgressIndicator()
                  : shot == null
                      ? const Icon(Icons.videocam, color: Colors.white24, size: 40)
                      : Image.file(shot, fit: BoxFit.contain, gaplessPlayback: true),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(c.model, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              Text(c.id, style: const TextStyle(color: Colors.white54, fontSize: 11)),
              const SizedBox(height: 10),
              DropdownButtonFormField<CameraPosition?>(
                key: ValueKey('${c.id}-$position'),
                initialValue: position,
                isExpanded: true,
                decoration:
                    const InputDecoration(labelText: 'Mounted at', isDense: true, border: OutlineInputBorder()),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Not used')),
                  for (final p in CameraPosition.compass)
                    DropdownMenuItem(value: p, child: Text(_optionLabel(p, c.id))),
                ],
                onChanged: (p) => _assign(c.id, p),
              ),
              const SizedBox(height: 6),
              Text('Tap the picture to take a new one.', style: const TextStyle(color: Colors.white38, fontSize: 11)),
            ]),
          ),
        ]),
      ),
    );
  }

  String _optionLabel(CameraPosition p, String id) {
    final holder = _mounted[p]?.camera ?? '';
    if (holder.isEmpty || holder == id) return p.label;
    return '${p.label} (replaces ${_modelOf(holder)})';
  }

  Widget _positionGrid() {
    const rows = [
      [CameraPosition.frontLeft, CameraPosition.front, CameraPosition.frontRight],
      [CameraPosition.left, null, CameraPosition.right],
      [CameraPosition.backLeft, CameraPosition.back, CameraPosition.backRight],
    ];
    Widget cell(CameraPosition? p) {
      if (p == null) {
        return const Center(child: Icon(Icons.directions_car, size: 48, color: Colors.white38));
      }
      final s = _mounted[p];
      final used = s?.assigned ?? false;
      return Container(
        margin: const EdgeInsets.all(3),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: used ? const Color(0xFF233046) : const Color(0xFF16161B),
          border: Border.all(color: used ? const Color(0xFF3D7EFF) : Colors.white12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(p.label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
          Text(used ? _modelOf(s!.camera) : 'empty',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: used ? Colors.white70 : Colors.white30, fontSize: 10)),
          if (used)
            Text(s!.calibrated ? 'calibrated' : 'not calibrated',
                style: TextStyle(color: s.calibrated ? _good : Colors.white38, fontSize: 10)),
        ]),
      );
    }

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Front', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, fontSize: 11)),
      AspectRatio(
        aspectRatio: 1,
        child: Column(children: [
          for (final r in rows)
            Expanded(child: Row(children: [for (final p in r) Expanded(child: cell(p))])),
        ]),
      ),
      const SizedBox(height: 8),
      const Text(
        'Each position holds one camera. Its picture in the views and its place in the '
        'surround calibration follow what is set here.',
        style: TextStyle(color: Colors.white54, fontSize: 11),
      ),
    ]);
  }
}
