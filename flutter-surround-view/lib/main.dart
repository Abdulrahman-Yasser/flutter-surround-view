import 'package:bev_calib/bev_calib.dart';
import 'package:flutter/material.dart';

import 'bev_source.dart';
import 'controls.dart';
import 'models.dart';
import 'settings_page.dart';
import 'viewport.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SurroundViewApp());
}

class SurroundViewApp extends StatelessWidget {
  const SurroundViewApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Surround View',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0C0C0E),
      ),
      home: const SurroundViewScreen(),
    );
  }
}

class SurroundViewScreen extends StatefulWidget {
  const SurroundViewScreen({super.key});

  @override
  State<SurroundViewScreen> createState() => _SurroundViewScreenState();
}

const Set<ViewMode> _fullScreenModes = <ViewMode>{
  ViewMode.surround360,
  ViewMode.frontRear,
};

class _SurroundViewScreenState extends State<SurroundViewScreen> {
  ViewMode _mode = ViewMode.surround360;
  CameraPosition _position = CameraPosition.front;
  CameraPosition _frontRearCamera = CameraPosition.front;
  final Map<CameraPosition, CameraSubView> _camSubView = <CameraPosition, CameraSubView>{
    for (final CameraPosition p in CameraPosition.values) p: CameraSubView.normal,
  };
  Map<CameraPosition, PositionState> _mounted = readMountedCameras();

  List<CameraPosition> get _mountedPositions => <CameraPosition>[
        for (final CameraPosition p in CameraPosition.compass)
          if (_mounted[p]?.assigned ?? false) p,
      ];
  final Set<CameraOverlay> _overlays = <CameraOverlay>{};
  bool _suspended = false;

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
      );
  }

  bool _transitioning = false;

  // Forces a frame with no BevView mounted before the next one is built, so
  // the outgoing view's platform-view dispose is sent before the incoming
  // one's create. Skipping this let create race dispose and starve the
  // camera release behind a blocked create call.
  void _switchView(VoidCallback applyChange) {
    if (_transitioning) return;
    setState(() => _transitioning = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        applyChange();
        _transitioning = false;
      });
    });
  }

  void _cameraTap(CameraPosition camera) => _switchView(() {
        if (_mode == ViewMode.camera && _position == camera) {
          _camSubView[camera] = _camSubView[camera]!.next;
        } else {
          _mode = ViewMode.camera;
          _position = camera;
          _camSubView[camera] = CameraSubView.normal;
        }
      });

  void _sideViewsTap() => _switchView(() {
        if (_mode == ViewMode.sideViews) {
          final CameraSubView next = _camSubView[CameraPosition.left]!.next;
          _camSubView[CameraPosition.left] = next;
          _camSubView[CameraPosition.right] = next;
        } else {
          _mode = ViewMode.sideViews;
          _camSubView[CameraPosition.left] = CameraSubView.normal;
          _camSubView[CameraPosition.right] = CameraSubView.normal;
        }
      });

  void _frontRearTap() => _switchView(() {
        if (_mode == ViewMode.frontRear) {
          _frontRearCamera = _frontRearCamera == CameraPosition.front
              ? CameraPosition.back
              : CameraPosition.front;
        } else {
          _mode = ViewMode.frontRear;
        }
      });

  void _toggleOverlay(CameraOverlay o) => setState(() {
        if (!_overlays.remove(o)) _overlays.add(o);
      });

  // Calibration needs the cameras, which a live BevView holds. A pushed route
  // keeps this screen mounted, so first build a frame with no view at all,
  // then open the page; the views come back (with the new calibration) on
  // return.
  Future<void> _openCalibration(Widget Function(CalibPaths paths) page,
      {String savedMessage = 'Calibration saved'}) async {
    if (_suspended) return;
    setState(() => _suspended = true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final bool? saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (BuildContext context) => page(calibPaths)),
    );
    if (!mounted) return;
    setState(() {
      _suspended = false;
      _mounted = readMountedCameras();
      final bool gone = switch (_mode) {
        ViewMode.camera => !_mountedPositions.contains(_position),
        ViewMode.sideViews =>
          !_mountedPositions.contains(CameraPosition.left) || !_mountedPositions.contains(CameraPosition.right),
        ViewMode.frontRear =>
          !_mountedPositions.contains(CameraPosition.front) || !_mountedPositions.contains(CameraPosition.back),
        ViewMode.surround360 => false,
      };
      if (gone) _mode = ViewMode.surround360;
    });
    if (saved == true) _toast(savedMessage);
  }

  void _openCameras() => _openCalibration((CalibPaths paths) => CamerasPage(paths: paths),
      savedMessage: 'Camera positions saved');

  void _openSurroundCalibration() =>
      _openCalibration((CalibPaths paths) => SurroundCalibrationPage(paths: paths));

  void _openLensCalibration() =>
      _openCalibration((CalibPaths paths) => LensCalibrationPage(paths: paths));

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => SettingsPage(
          paths: calibPaths,
          onSurroundCalibration: _openSurroundCalibration,
          onLensCalibration: _openLensCalibration,
          onCameras: _openCameras,
        ),
      ),
    );
  }

  String _modeTagLabel() {
    switch (_mode) {
      case ViewMode.surround360:
        return '360° view';
      case ViewMode.frontRear:
        return '${_frontRearCamera.label} view';
      case ViewMode.camera:
        final CameraSubView sub = _camSubView[_position]!;
        return sub == CameraSubView.normal
            ? '${_position.label} view'
            : '${_position.label} - ${sub.label}';
      case ViewMode.sideViews:
        final CameraSubView sub = _camSubView[CameraPosition.left]!;
        return sub == CameraSubView.normal
            ? 'Left + Right view'
            : 'Left + Right - ${sub.label}';
    }
  }

  Widget _controlledView() {
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: _transitioning
              ? const ColoredBox(color: Color(0xFF0A0A0C))
              : CameraViewport(
                  mode: _mode,
                  position: _position,
                  mounted: _mounted,
                  overlays: _overlays,
                  camSubViews: _camSubView,
                  frontRearCamera: _frontRearCamera,
                ),
        ),
        Positioned(
          left: 10,
          top: 10,
          child: _ModeTag(label: _modeTagLabel()),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_suspended) {
      return const Scaffold(backgroundColor: Color(0xFF0A0A0C));
    }
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: _fullScreenModes.contains(_mode)
                  ? _controlledView()
                  : Row(
                      children: <Widget>[
                        Expanded(flex: 7, child: _controlledView()),
                        Expanded(
                          flex: 3,
                          child: ColoredBox(
                            color: const Color(0xFF0A0A0C),
                            child: BevPlaceholder(mounted: _mounted),
                          ),
                        ),
                      ],
                    ),
            ),
            TopToolbar(
              mode: _mode,
              position: _position,
              mounted: _mountedPositions,
              onSurroundTap: () => _switchView(() => _mode = ViewMode.surround360),
              camSubViews: _camSubView,
              onCameraTap: _cameraTap,
              onSideViewsTap: _sideViewsTap,
              frontRearCamera: _frontRearCamera,
              onFrontRearTap: _frontRearTap,
              overlays: _overlays,
              onToggleOverlay: _toggleOverlay,
              onCalibrate: _openSurroundCalibration,
              onSnapshot: () => _toast('Snapshot saved (mock)'),
              onSettings: _openSettings,
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeTag extends StatelessWidget {
  const _ModeTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
