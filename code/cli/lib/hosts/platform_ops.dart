/// Cross-platform abstraction for OS-specific shell operations that have no
/// equivalent in `modular_cli_sdk`'s `InstallationPlugin`.
///
/// Binary replacement and uninstall-directory deletion moved to
/// `InstallationPlugin` (ccisnedev/inquiry#321): what remains here is
/// environment-variable access, used by the uninstall PATH cleanup,
/// post-install host redeployment, used after an upgrade, and archive
/// extraction, used to refresh the bundled `assets/` folder after an
/// upgrade (`InstallationPlugin` itself only ever writes a bare executable).
///
/// Path manipulation is NOT part of this abstraction — use `package:path`.
library;

import 'dart:io';

import 'linux_platform_ops.dart';
import 'windows_platform_ops.dart';

/// Abstract contract for platform-specific operations.
///
/// Implementations: [WindowsPlatformOps], [LinuxPlatformOps].
/// For tests: create a fake that implements this class.
abstract class PlatformOps {
  /// Read a system environment variable. Returns `null` if not set.
  String? getEnvVariable(String name);

  /// Write a system environment variable.
  Future<void> setEnvVariable(String name, String value);

  /// Run post-install steps ([postInstallArguments]) using the correct binary.
  ///
  /// Returns the child's result so the caller can report what was deployed —
  /// a step whose output is swallowed is indistinguishable from one that did
  /// nothing (#300).
  ///
  /// Implementations must be bounded by [postInstallTimeout]: this runs after
  /// the upgrade has already succeeded, so it may fail but must never block.
  Future<ProcessResult> runPostInstall(String installDir);

  /// Extracts the archive at [archivePath] into [destDir], which must
  /// already exist.
  ///
  /// Used only to refresh the bundled `assets/` folder after `upgrade`
  /// (ccisnedev/inquiry#321): `InstallationPlugin`'s own binary replacement
  /// downloads a bare per-platform executable, never an archive — see its
  /// own doc comment on why it deliberately does not support one. Inquiry
  /// still ships `assets/` alongside the binary, so `refreshAssetsAfterUpgrade`
  /// downloads the same platform archive `install.ps1` / `install.sh` use
  /// for a first install, and this extracts it into a scratch directory to
  /// pull just that folder back out.
  Future<void> expandArchive(String archivePath, String destDir);

  /// Factory that returns the correct implementation for the current OS.
  factory PlatformOps.current() {
    if (Platform.isWindows) return WindowsPlatformOps();
    if (Platform.isLinux) return LinuxPlatformOps();
    throw UnsupportedError(
      'PlatformOps: unsupported OS "${Platform.operatingSystem}"',
    );
  }
}

/// How long post-install deployment may take before it is abandoned.
///
/// Generous enough for a cold filesystem, short enough that a stalled step
/// reports rather than hanging the terminal (#300).
const postInstallTimeout = Duration(seconds: 60);

/// What the freshly installed binary is asked to do after an upgrade.
///
/// `--apply --autoapprove` is not a shortcut past the gate — it is the gate,
/// honored. The user already approved this upgrade, of which redeploying the
/// hosts is a named step; there is no second decision to take, and no terminal
/// to take it on. Without the flags the child would ask "--plan or --apply?"
/// into a pipe nobody reads and exit non-zero, and every upgrade would report a
/// failed redeploy.
///
/// Shared by both platforms so the two cannot drift, and named so a test can
/// pin it.
const postInstallArguments = ['host', 'get', '--apply', '--autoapprove'];
