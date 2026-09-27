/// `inquiry uninstall` cleanup — runs before `modular_cli_sdk`'s own
/// [InstallationPlugin] removes the binary.
///
/// The plugin owns the `uninstall` route itself (and the Windows-safe wait
/// for this process to exit before deleting anything — see
/// ccisnedev/inquiry#321). What it does not know about is Inquiry-specific:
/// the hosts this CLI deployed into, the repository-scoped agent file, and
/// this CLI's own PATH entry. [runUninstallCleanup] does exactly that, and
/// is wired in ahead of the plugin's own route via `ModularCli.use`.
///
/// `InstallationPlugin`'s own `uninstall` route handles the actual removal.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../hosts/deployer.dart';
import '../../../hosts/platform_ops.dart';

/// Cleans every host this machine deployed to, removes the repository-scoped
/// agent file (if the current working directory is inside one), and takes
/// `<installDir>/bin` off the user's PATH.
///
/// Order is not cosmetic: hosts are cleaned first, while the assets they were
/// deployed from are still on disk, and PATH is unset before the
/// `InstallationPlugin`'s own `uninstall` route schedules the installation
/// directory for deletion, so there is never a window in which the entry
/// points at a directory already on its way out.
void runUninstallCleanup({
  required HostDeployer deployer,
  required String installDir,
  PlatformOps? platformOps,
  String? workingDirectory,
}) {
  final ops = platformOps ?? PlatformOps.current();
  final cwd = workingDirectory ?? Directory.current.path;

  deployer.clean();

  final repoAgent = File(p.join(cwd, '.github', 'agents', 'inquiry.agent.md'));
  if (repoAgent.existsSync()) {
    repoAgent.deleteSync();
  }

  final binDir = p.join(installDir, 'bin');
  _unsetFromPath(platformOps: ops, binDir: binDir);
  _removeAliasShim(binDir: binDir);
}

// `InstallationPlugin`'s own `uninstall` route only removes an alias that
// `sameFile()`s the executable (a symlink or hard link to it): it leaves
// alone an alias that resolves to a different file rather than guessing.
// On Windows the `iq` alias is `iq.cmd`, a batch shim calling
// `%~dp0inquiry.exe` — a distinct file, not a link — so without this it
// would survive `iq uninstall` (ccisnedev/inquiry#321).
void _removeAliasShim({required String binDir}) {
  final shim = File(p.join(binDir, 'iq.cmd'));
  if (shim.existsSync()) {
    shim.deleteSync();
  }
}

void _unsetFromPath({
  required PlatformOps platformOps,
  required String binDir,
}) {
  final userPath = platformOps.getEnvVariable('PATH') ?? '';
  final separator = Platform.isWindows ? ';' : ':';
  final parts = userPath
      .split(separator)
      .where((part) => part.isNotEmpty)
      .where((part) => !_pathEquals(part, binDir))
      .toList();
  final newPath = parts.join(separator);

  if (newPath != userPath) {
    platformOps.setEnvVariable('PATH', newPath);
  }
}

bool _pathEquals(String a, String b) =>
    p.normalize(a).toLowerCase() == p.normalize(b).toLowerCase();
