/// Linux implementation of [PlatformOps].
///
/// Uses the shell environment for variables. Binary replacement and
/// uninstall-directory deletion are handled by `modular_cli_sdk`'s
/// `InstallationPlugin` (ccisnedev/inquiry#321); [expandArchive] extracts
/// the archive `refreshAssetsAfterUpgrade` downloads to refresh the
/// bundled `assets/` folder, which that plugin does not manage.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'platform_ops.dart';

/// Concrete [PlatformOps] for Linux.
class LinuxPlatformOps implements PlatformOps {
  static const _binaryName = 'inquiry';

  @override
  String? getEnvVariable(String name) {
    return Platform.environment[name];
  }

  @override
  Future<void> setEnvVariable(String name, String value) async {
    // On Linux, persistent env vars require modifying shell profiles.
    // This is a no-op at runtime — print guidance instead.
    // The install.sh script handles PATH setup during installation.
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
    final result = await Process.run('tar', [
      'xzf',
      archivePath,
      '-C',
      destDir,
    ]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'tar',
        ['xzf', archivePath, '-C', destDir],
        'Failed to extract archive: ${result.stderr}',
        result.exitCode,
      );
    }
  }
}
