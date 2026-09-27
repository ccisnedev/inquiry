/// Cross-platform abstraction for OS-specific shell operations.
///
/// PlatformOps wraps operations that differ between Windows and Linux:
/// archive extraction, environment variables, binary replacement, etc.
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
  /// The compiled binary name for this platform (e.g. `inquiry.exe` or `inquiry`).
  String get binaryName;

  /// The release asset name for this platform (e.g. `inquiry-windows-x64.zip`).
  String get assetName;

  /// Extract an archive to [destDir].
  ///
  /// Windows: PowerShell `Expand-Archive`.
  /// Linux: `tar xzf`.
  Future<void> expandArchive(String archivePath, String destDir);

  /// Read a system environment variable. Returns `null` if not set.
  String? getEnvVariable(String name);

  /// Write a system environment variable.
  Future<void> setEnvVariable(String name, String value);

  /// Replace the currently running binary with a new one.
  ///
  /// Handles OS-specific locking and permission issues.
  Future<void> selfReplace(String newBinaryPath, String currentBinaryPath);

  /// Run post-install steps ([postInstallArguments]) using the correct binary.
  ///
  /// Returns the child's result so the caller can report what was deployed —
  /// a step whose output is swallowed is indistinguishable from one that did
  /// nothing (#300).
  ///
  /// Implementations must be bounded by [postInstallTimeout]: this runs after
  /// the upgrade has already succeeded, so it may fail but must never block.
  Future<ProcessResult> runPostInstall(String installDir);

  /// Schedule deletion of a directory after the current process exits.
  ///
  /// Windows: rename running exe, spawn detached `cmd /c timeout ... rmdir`.
  /// Linux: spawn detached `rm -rf`.
  Future<void> scheduleDeletion(String dir);

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
