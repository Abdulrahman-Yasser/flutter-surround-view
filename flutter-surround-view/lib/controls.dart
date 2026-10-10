import 'package:bev_calib/bev_calib.dart';
import 'package:flutter/material.dart';

import 'models.dart';

const Color _accent = Color(0xFF3D7EFF);
const Color _barColor = Color(0xFF15151A);

enum _QuickAction { guidelines, distanceGrid, snapshot, calibrate }

class TopToolbar extends StatelessWidget {
  const TopToolbar({
    super.key,
    required this.mode,
    required this.position,
    required this.mounted,
    required this.onSurroundTap,
    required this.camSubViews,
    required this.onCameraTap,
    required this.onSideViewsTap,
    required this.frontRearCamera,
    required this.onFrontRearTap,
    required this.overlays,
    required this.onToggleOverlay,
    required this.onCalibrate,
    required this.onSnapshot,
    required this.onSettings,
    required this.onClose,
    this.backendConnected = false,
  });

  final ViewMode mode;
  final CameraPosition position;
  final List<CameraPosition> mounted;
  final VoidCallback onSurroundTap;
  final Map<CameraPosition, CameraSubView> camSubViews;
  final ValueChanged<CameraPosition> onCameraTap;
  final VoidCallback onSideViewsTap;
  final CameraPosition frontRearCamera;
  final VoidCallback onFrontRearTap;
  final Set<CameraOverlay> overlays;
  final ValueChanged<CameraOverlay> onToggleOverlay;
  final VoidCallback onCalibrate;
  final VoidCallback onSnapshot;
  final VoidCallback onSettings;
  final VoidCallback onClose;
  final bool backendConnected;

  String _camLabel(String base, CameraPosition camera, bool selected) {
    final CameraSubView sub = camSubViews[camera]!;
    if (!selected || sub == CameraSubView.normal) return base;
    return '$base · ${sub.shortLabel}';
  }

  @override
  Widget build(BuildContext context) {
    final bool sideViewsSelected = mode == ViewMode.sideViews;
    final bool hasSides = mounted.contains(CameraPosition.left) && mounted.contains(CameraPosition.right);
    final bool hasFrontRear = mounted.contains(CameraPosition.front) && mounted.contains(CameraPosition.back);
    return Container(
      height: 46,
      color: _barColor,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  _ToolbarButton(
                    icon: Icons.threesixty,
                    label: '360 degree',
                    selected: mode == ViewMode.surround360,
                    onTap: onSurroundTap,
                  ),
                  for (final CameraPosition p in mounted)
                    _ToolbarButton(
                      icon: Icons.arrow_upward,
                      turns: (90 - p.facingDeg) / 360,
                      label: _camLabel(p.label, p, mode == ViewMode.camera && position == p),
                      selected: mode == ViewMode.camera && position == p,
                      onTap: () => onCameraTap(p),
                    ),
                  if (hasSides)
                    _ToolbarButton(
                      icon: Icons.view_column,
                      label: _camLabel('Side views', CameraPosition.left, sideViewsSelected),
                      selected: sideViewsSelected,
                      onTap: onSideViewsTap,
                    ),
                  if (hasFrontRear)
                    _ToolbarButton(
                      icon: mode == ViewMode.frontRear
                          ? (frontRearCamera == CameraPosition.front ? Icons.arrow_upward : Icons.arrow_downward)
                          : Icons.swap_vert,
                      label: 'Rear/Front cameras',
                      selected: mode == ViewMode.frontRear,
                      onTap: onFrontRearTap,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          _QuickActionsMenu(
            overlays: overlays,
            onToggleOverlay: onToggleOverlay,
            onCalibrate: onCalibrate,
            onSnapshot: onSnapshot,
          ),
          const SizedBox(width: 6),
          _ToolbarButton(
            icon: Icons.settings,
            label: 'Settings',
            selected: false,
            onTap: onSettings,
          ),
          _ToolbarButton(
            icon: Icons.power_settings_new,
            label: 'Close',
            selected: false,
            onTap: onClose,
          ),
          const SizedBox(width: 8),
          _BackendPill(connected: backendConnected),
        ],
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.selected,
    this.turns = 0,
  });

  final IconData icon;
  final double turns;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final Color fg = selected ? Colors.white : Colors.white70;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: selected ? _accent : Colors.white10,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                RotationTransition(
                  turns: AlwaysStoppedAnimation<double>(turns),
                  child: Icon(icon, size: 14, color: fg),
                ),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 10),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickActionsMenu extends StatelessWidget {
  const _QuickActionsMenu({
    required this.overlays,
    required this.onToggleOverlay,
    required this.onCalibrate,
    required this.onSnapshot,
  });

  final Set<CameraOverlay> overlays;
  final ValueChanged<CameraOverlay> onToggleOverlay;
  final VoidCallback onCalibrate;
  final VoidCallback onSnapshot;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_QuickAction>(
      tooltip: 'More',
      color: const Color(0xFF1B1B21),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<_QuickAction>>[
        CheckedPopupMenuItem<_QuickAction>(
          value: _QuickAction.guidelines,
          checked: overlays.contains(CameraOverlay.guidelines),
          child: const Text('Guides'),
        ),
        CheckedPopupMenuItem<_QuickAction>(
          value: _QuickAction.distanceGrid,
          checked: overlays.contains(CameraOverlay.distanceGrid),
          child: const Text('Distance grid'),
        ),
        const PopupMenuItem<_QuickAction>(
          value: _QuickAction.calibrate,
          child: Text('Calibrate'),
        ),
        const PopupMenuItem<_QuickAction>(
          value: _QuickAction.snapshot,
          child: Text('Snapshot'),
        ),
      ],
      onSelected: (_QuickAction action) {
        switch (action) {
          case _QuickAction.guidelines:
            onToggleOverlay(CameraOverlay.guidelines);
          case _QuickAction.distanceGrid:
            onToggleOverlay(CameraOverlay.distanceGrid);
          case _QuickAction.calibrate:
            onCalibrate();
          case _QuickAction.snapshot:
            onSnapshot();
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(6),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.more_horiz, size: 14, color: Colors.white70),
            SizedBox(width: 2),
            Icon(Icons.keyboard_arrow_down, size: 12, color: Colors.white70),
          ],
        ),
      ),
    );
  }
}

class _BackendPill extends StatelessWidget {
  const _BackendPill({required this.connected});

  final bool connected;

  @override
  Widget build(BuildContext context) {
    final Color c = connected ? const Color(0xFF43A047) : const Color(0xFFFFB300);
    return Tooltip(
      message: connected
          ? 'gRPC control link up'
          : 'gRPC WatchState - not wired yet',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            connected ? 'backend' : 'mock',
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
