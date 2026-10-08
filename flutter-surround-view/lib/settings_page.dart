import 'package:bev_calib/bev_calib.dart';
import 'package:flutter/material.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.paths,
    required this.onSurroundCalibration,
    required this.onLensCalibration,
    required this.onCameras,
  });

  final CalibPaths paths;
  final VoidCallback onSurroundCalibration;
  final VoidCallback onLensCalibration;
  final VoidCallback onCameras;

  @override
  Widget build(BuildContext context) {
    const TextStyle small = TextStyle(color: Colors.white54, fontSize: 12);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            const Text(
              'Cameras',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.videocam),
                title: const Text('Camera positions'),
                subtitle: const Text(
                  'Which camera is mounted where on the car: front, back, sides and corners',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: onCameras,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Camera calibration',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.grid_on),
                title: const Text('Surround calibration'),
                subtitle: const Text(
                  'Boards around the car: aligns every camera into the top view',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: onSurroundCalibration,
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.camera),
                title: const Text('Lens calibration'),
                subtitle: const Text(
                  'One board, many poses: measures a lens so its distortion is removed',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: onLensCalibration,
              ),
            ),
            const SizedBox(height: 12),
            Text('Config: ${paths.configPath}', style: small),
            Text('Lens files: ${paths.lensDir}', style: small),
            Text('Layouts: ${paths.layoutsDir}', style: small),
          ],
        ),
      ),
    );
  }
}
