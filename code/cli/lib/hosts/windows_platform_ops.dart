/// Windows implementation of [PlatformOps].
///
/// Uses PowerShell for environment variable management. Binary replacement
/// and uninstall-directory deletion are handled by `modular_cli_sdk`'s
/// `InstallationPlugin` (ccisnedev/inquiry#321); `expandArchive` extracts
/// the archive `refreshAssetsAfterUpgrade` downloads to refresh the
/// bundled `assets/` folder, which that plugin does not manage.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'platform_ops.dart';

/// Concrete [PlatformOps] for Windows.
class WindowsPlatformOps implements PlatformOps {
  static const _binaryName = 'inquiry.exe';

  @override
  String? getEnvVariable(String name) {
    final result = Process.runSync('powershell', [
      '-NoProfile',
      '-Command',
      '[System.Environment]::GetEnvironmentVariable("$name", "User")',
    ]);
    if (result.exitCode != 0) return null;
    final value = (result.stdout as String).trim();
    return value.isEmpty ? null : value;
  }

  @override
  Future<void> setEnvVariable(String name, String value) async {
    Process.runSync('powershell', [
      '-NoProfile',
      '-Command',
      '[System.Environment]::SetEnvironmentVariable("$name", "$value", "User")',
    ]);
  }

  @override
  Future<ProcessResult> runPostInstall(String installDir) async {
    // Bounded: `host get` only touches the filesystem now, but it runs the
    // freshly written binary and its output is buffered rather than streamed,
    // so an unbounded wait here is indistinguishable from a crash (#300).
    return Process.run(
      p.join(installDir, 'bin', _binaryName),
      postInstallArguments,
    ).timeout(
      postInstallTimeout,
      onTimeout: () => throw TimeoutException(
        'host get did not finish within ${postInstallTimeout.inSeconds}s',
      ),
    );
  }

  @override
  Future<void> expandArchive(String archivePath, String destDir) async {
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      'Expand-Archive -Path "$archivePath" -DestinationPath "$destDir" -Force',
    ]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'powershell',
        ['Expand-Archive'],
        'Failed to extract archive: ${result.stderr}',
        result.exitCode,
      );
    }
  }
}
