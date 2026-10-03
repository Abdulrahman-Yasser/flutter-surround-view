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

ViewMode _viewModeForCamera(CameraId camera) => switch (camera) {
      CameraId.front => ViewMode.front,
      CameraId.rear => ViewMode.rear,
      CameraId.left => ViewMode.left,
      CameraId.right => ViewMode.right,
    };

class _SurroundViewScreenState extends State<SurroundViewScreen> {
  ViewMode _mode = ViewMode.surround360;
  CameraId _frontRearCamera = CameraId.front;
  final Map<CameraId, CameraSubView> _camSubView = <CameraId, CameraSubView>{
    for (final CameraId c in CameraId.values) c: CameraSubView.normal,
  };
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

  void _cameraTap(CameraId camera) => _switchView(() {
        final ViewMode m = _viewModeForCamera(camera);
        if (_mode == m) {
          _camSubView[camera] = _camSubView[camera]!.next;
        } else {
          _mode = m;
          _camSubView[camera] = CameraSubView.normal;
        }
      });

  void _sideViewsTap() => _switchView(() {
        if (_mode == ViewMode.sideViews) {
          final CameraSubView next = _camSubView[CameraId.left]!.next;
          _camSubView[CameraId.left] = next;
          _camSubView[CameraId.right] = next;
        } else {
          _mode = ViewMode.sideViews;
          _camSubView[CameraId.left] = CameraSubView.normal;
          _camSubView[CameraId.right] = CameraSubView.normal;
        }
      });

  void _frontRearTap() => _switchView(() {
        if (_mode == ViewMode.frontRear) {
          _frontRearCamera = _frontRearCamera == CameraId.front
              ? CameraId.rear
              : CameraId.front;
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
  Future<void> _openCalibration(Widget Function(CalibPaths paths) page) async {
    if (_suspended) return;
    setState(() => _suspended = true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final bool? saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (BuildContext context) => page(calibPaths)),
    );
    if (!mounted) return;
    setState(() => _suspended = false);
    if (saved == true) _toast('Calibration saved');
  }

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
        ),
      ),
    );
  }

  String _modeTagLabel() {
    if (_mode == ViewMode.frontRear) return '${_frontRearCamera.label} view';
    final CameraId? cam = _mode.asCamera;
    if (cam != null) {
      final CameraSubView sub = _camSubView[cam]!;
      return sub == CameraSubView.normal
          ? '${_mode.label} view'
          : '${_mode.label} - ${sub.label}';
    }
    if (_mode == ViewMode.sideViews) {
      final CameraSubView sub = _camSubView[CameraId.left]!;
      return sub == CameraSubView.normal
          ? 'Left + Right view'
          : 'Left + Right - ${sub.label}';
    }
    return '${_mode.label} view';
  }

  Widget _controlledView() {
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: _transitioning
              ? const ColoredBox(color: Color(0xFF0A0A0C))
              : CameraViewport(
                  mode: _mode,
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
                        const Expanded(
                          flex: 3,
                          child: ColoredBox(
                            color: Color(0xFF0A0A0C),
                            child: BevPlaceholder(),
                          ),
                        ),
                      ],
                    ),
            ),
            TopToolbar(
              mode: _mode,
              onModeChanged: (ViewMode m) => _switchView(() => _mode = m),
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
