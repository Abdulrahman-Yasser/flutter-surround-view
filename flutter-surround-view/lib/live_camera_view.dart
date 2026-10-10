import 'dart:async';
import 'dart:io';

import 'package:bev_calib/bev_calib.dart';
import 'package:bev_view/bev_view.dart';
import 'package:flutter/material.dart';

import 'bev_source.dart';

class LiveCameraView extends StatefulWidget {
  const LiveCameraView({
    super.key,
    required this.position,
    required this.cameraId,
    required this.birdsEye,
    this.flat = false,
    this.showLabel = false,
  });

  final CameraPosition position;
  final String cameraId;

  /// The fisheye-corrected (undistorted) picture instead of the raw one.
  final bool flat;
  final bool birdsEye;
  final bool showLabel;

  @override
  State<LiveCameraView> createState() => _LiveCameraViewState();
}

class _LiveCameraViewState extends State<LiveCameraView> {
  static final bool _showStats = Platform.environment['BEV_STAT'] == '1';

  Timer? _poll;
  BevStats? _stats;

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _onCreated(BevViewController controller) {
    if (!_showStats) return;
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final BevStats? stats = controller.stats();
      if (!mounted) return;
      setState(() => _stats = stats);
    });
  }

  @override
  Widget build(BuildContext context) {
    final CameraPosition position = widget.position;
    final bool birdsEye = widget.birdsEye;
    final BevSource source = birdsEye
        ? birdsEyeSource(position)
        : widget.flat
            ? flatSource(position)
            : cameraSource(widget.cameraId);
    return Container(
      margin: const EdgeInsets.all(3),
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(color: Colors.white12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          BevView(
            key: ValueKey<String>('${widget.cameraId}-${position.key}-$birdsEye-${widget.flat}'),
            source: source,
            onCreated: _onCreated,
          ),
          if (_showStats && _stats != null)
            Positioned(
              right: 8,
              top: 8,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Text(
                      '${_stats!.fps.toStringAsFixed(1)} fps',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (widget.showLabel)
            Positioned(
              left: 8,
              top: 8,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(
                    birdsEye ? '${position.label} BEV' : widget.flat ? '${position.label} 2D' : position.label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
