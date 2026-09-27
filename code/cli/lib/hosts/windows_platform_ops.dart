/// Windows implementation of [PlatformOps].
///
/// Uses PowerShell for archive extraction and environment variable management.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'platform_ops.dart';

/// Concrete [PlatformOps] for Windows.
class WindowsPlatformOps implements PlatformOps {
  @override
  String get binaryName => 'inquiry.exe';

  @override
  String get assetName => 'inquiry-windows-x64.zip';

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
  Future<void> selfReplace(
    String newBinaryPath,
    String currentBinaryPath,
  ) async {
    final bakPath = freeBackupPath(currentBinaryPath);

    // Rename the running exe — Windows allows renaming a locked file
    File(currentBinaryPath).renameSync(bakPath);

    // Copy the new binary into place
    File(newBinaryPath).copySync(currentBinaryPath);

    // Best-effort cleanup
    try {
      File(bakPath).deleteSync();
    } on FileSystemException {
      // Still locked — swept on a later upgrade.
    }
  }


  @override
  Future<ProcessResult> runPostInstall(String installDir) async {
    // Bounded: `host get` only touches the filesystem now, but it runs the
    // freshly written binary and its output is buffered rather than streamed,
    // so an unbounded wait here is indistinguishable from a crash (#300).
    return Process.run(
      p.join(installDir, 'bin', binaryName),
      postInstallArguments,
    ).timeout(
      postInstallTimeout,
      onTimeout: () => throw TimeoutException(
        'host get did not finish within ${postInstallTimeout.inSeconds}s',
      ),
    );
  }

  @override
  Future<void> scheduleDeletion(String dir) async {
    // Rename the running exe so the directory can be deleted.
    final currentExe = File(Platform.resolvedExecutable);
    final bakPath = '${Platform.resolvedExecutable}.bak';
    try {
      currentExe.renameSync(bakPath);
    } on FileSystemException {
      // Best effort — may already be renamed
    }

    // Write a temp batch script to avoid cmd.exe quoting issues
    // (Dart escapes " in Process.start args, but cmd doesn't understand \")
    final bat = File(p.join(Directory.systemTemp.path, 'inquiry_cleanup.cmd'));
    bat.writeAsStringSync(
      '@echo off\r\n'
      'timeout /t 2 /nobreak >nul\r\n'
      'rmdir /s /q "$dir"\r\n'
      'del "%~f0"\r\n',
    );

    await Process.start(
      'cmd.exe',
      ['/c', bat.path],
      mode: ProcessStartMode.detached,
    );
  }
}

/// A backup path the rename can use, sweeping what it can along the way.
///
/// `<exe>.bak` may exist *and* be undeletable: Windows refuses to remove the
/// image of a running process, so a backup left by an upgrade whose child
/// outlived it stays locked indefinitely. Deleting it unguarded aborted the
/// entire upgrade — with an error naming a temp file rather than the cause,
/// and no way forward short of finding the stray process by hand.
///
/// A locked leftover is now stepped over rather than fatal: numbered
/// candidates are tried until one is free. Failing that, the error says what
/// is actually wrong.
String freeBackupPath(String currentBinaryPath) {
  for (var i = 0; i < 20; i++) {
    final path = '$currentBinaryPath.bak${i == 0 ? '' : i}';
    // `File.existsSync` is false for a directory at the same path, which would
    // report an occupied name as free and then fail the rename instead.
    if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) {
      return path;
    }
    try {
      File(path).deleteSync();
      return path;
    } on FileSystemException {
      // Locked by a live process — try the next name.
    }
  }

  throw FileSystemException(
    'Could not free a backup path for the running binary. An inquiry '
    "process is probably still running: check with 'Get-Process inquiry', "
    'stop it, and retry the upgrade',
    currentBinaryPath,
  );
}
