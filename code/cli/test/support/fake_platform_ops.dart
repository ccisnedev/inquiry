import 'dart:io';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';

/// A fake `modular_cli_sdk` [PlatformOps], for testing inquiry's own extra
/// installation steps (`RedeployHosts`, `commands/upgrade.dart`) without
/// touching a real archive, environment, or child process.
///
/// Modeled on the SDK's own `FakePlatformOps`
/// (`test/plugins/installation_doubles.dart` in `modular_cli_sdk`), which is
/// itself modeled on this file's predecessor (`platform_ops_test.dart`'s
/// `FakePlatformOps`, for inquiry's own, now-removed `PlatformOps`
/// interface).
class FakePlatformOps implements PlatformOps {
  FakePlatformOps({
    this.binaryName = 'inquiry',
    this.assetName = 'inquiry-fake.zip',
    this.fakeEnvValue,
    this.runPostInstallError,
    ProcessResult? postInstallResult,
  }) : postInstallResult =
           postInstallResult ??
           ProcessResult(
             0,
             0,
             'Inquiry agent + skills deployed to host claude',
             '',
           );

  @override
  final String binaryName;

  @override
  final String assetName;

  /// What [getEnvVariable] returns for every name.
  final String? fakeEnvValue;

  /// Thrown by [runPostInstall] instead of returning, standing in for a
  /// child process that could not even launch.
  final Object? runPostInstallError;

  /// What [runPostInstall] returns when it does not throw. What the fake
  /// child reports back: `RedeployHosts` echoes this, so a test can assert
  /// the user is shown which hosts were deployed to.
  ProcessResult postInstallResult;

  /// Every call this fake received, in order, as a human-readable line.
  final List<String> calls = [];

  @override
  Future<void> expandArchive(String archivePath, String destDir) async {
    calls.add('expandArchive($archivePath, $destDir)');
  }

  @override
  String? getEnvVariable(String name) {
    calls.add('getEnvVariable($name)');
    return fakeEnvValue;
  }

  @override
  Future<void> setEnvVariable(String name, String value) async {
    calls.add('setEnvVariable($name, $value)');
  }

  @override
  Future<ProcessResult> runPostInstall(
    String installDir, {
    Duration? timeout,
  }) async {
    calls.add(
      timeout == null
          ? 'runPostInstall($installDir)'
          : 'runPostInstall($installDir, timeout: $timeout)',
    );
    if (runPostInstallError != null) throw runPostInstallError!;
    return postInstallResult;
  }

  @override
  Future<void> scheduleDeletion(String dir) async {
    calls.add('scheduleDeletion($dir)');
  }
}
