// Native-assets build hook. Builds libbev_calib.so -- calib/ in this repository,
// OpenCV and libcamera, no GPU -- from the top-level CMakeLists.txt, and
// publishes it under the id lib/src/ffi/bev_calib_ffi.dart names in its
// @DefaultAsset.
//
// The hook runner strips the environment, so configuration comes from
// user-defines in the consuming app's pubspec.yaml:
//
//   hooks:
//     user_defines:
//       bev_calib:
//         build_type: Release               # CMAKE_BUILD_TYPE (default Release)
//         cmake_toolchain_file: <path>      # cross builds
//         pkg_config_path: <dirs>           # e.g. a libcamera installed outside /usr
//         clear_ambient_flags: true         # drop CFLAGS/CXXFLAGS/LDFLAGS

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final repoRoot = input.packageRoot.resolve('../../').toFilePath();
    final buildDir = input.outputDirectory.resolve('cmake/').toFilePath();
    await Directory(buildDir).create(recursive: true);

    final toolchain = _dir(input, 'cmake_toolchain_file');
    final buildType = _string(input, 'build_type') ?? 'Release';
    final pkgConfigPath = _string(input, 'pkg_config_path');
    final env = <String, String>{
      if (_flag(input, 'clear_ambient_flags')) ...{'CFLAGS': '', 'CXXFLAGS': '', 'LDFLAGS': ''},
      'PKG_CONFIG_PATH': ?pkgConfigPath,
    };

    await _run('cmake', [
      '-S', repoRoot,
      '-B', buildDir,
      '-DCMAKE_BUILD_TYPE=$buildType',
      '-DENABLE_CALIB=ON',
      '-DENABLE_IHS_PV=OFF',
      if (toolchain != null) '-DCMAKE_TOOLCHAIN_FILE=$toolchain',
      if (!File('${buildDir}CMakeCache.txt').existsSync() && await _which('ninja')) ...[
        '-G',
        'Ninja',
      ],
    ], environment: env.isEmpty ? null : env);

    await _run(
      'cmake',
      ['--build', buildDir, '--target', 'bev_calib', '--parallel'],
      environment: env.isEmpty ? null : env,
    );

    final lib = File('${buildDir}libbev_calib.so');
    if (!lib.existsSync()) {
      throw StateError('libbev_calib.so not found at ${lib.path}');
    }
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'src/ffi/bev_calib_ffi.dart',
        linkMode: DynamicLoadingBundled(),
        file: lib.uri,
      ),
    );

    for (final dir in [repoRoot, '${repoRoot}calib']) {
      for (final entity in Directory(dir).listSync()) {
        if (entity is File &&
            (entity.path.endsWith('.cpp') || entity.path.endsWith('.h'))) {
          output.dependencies.add(entity.uri);
        }
      }
    }
    output.dependencies.add(Uri.file('${repoRoot}CMakeLists.txt'));
  });
}

String? _string(BuildInput input, String define) {
  final value = input.userDefines[define];
  return value == null || '$value'.isEmpty ? null : '$value';
}

String? _dir(BuildInput input, String define) {
  final value = _string(input, define);
  if (value == null) return null;
  return value.startsWith('/')
      ? value
      : input.packageRoot.resolve(value).toFilePath();
}

bool _flag(BuildInput input, String define) {
  final value = input.userDefines[define];
  return value == true || (value is String && value != '' && value != '0' && value != 'false');
}

Future<bool> _which(String exe) async {
  try {
    final r = await Process.run('sh', ['-c', 'command -v $exe']);
    return r.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

Future<void> _run(
  String exe,
  List<String> args, {
  Map<String, String>? environment,
}) async {
  final proc = await Process.start(
    exe,
    args,
    environment: environment,
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await proc.exitCode;
  if (code != 0) {
    throw ProcessException(exe, args, 'exit code $code', code);
  }
}
