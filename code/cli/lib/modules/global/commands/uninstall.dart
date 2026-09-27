/// `inquiry uninstall` — removes Inquiry CLI from the system.
///
/// 1. Cleans all deployed hosts (agents + skills).
/// 2. Removes inquiry\bin\ from the user PATH.
/// 3. Spawns a background process to delete the install directory.
library;

import 'dart:io';

import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:path/path.dart' as p;

import '../../../hosts/deployer.dart';
import '../../../hosts/platform_ops.dart';

// ─── Input ──────────────────────────────────────────────────────────────────

class UninstallInput extends Input {
  final String installDir;

  UninstallInput({required this.installDir});

  factory UninstallInput.fromCliRequest(CliRequest req) {
    final installDir = p.dirname(p.dirname(Platform.resolvedExecutable));
    return UninstallInput(installDir: installDir);
  }

  /// Declares an EMPTY contract: this command accepts no option at all, so any
  /// option passed to it is refused. Omitting `contract` would mean "declares
  /// nothing" — which is how `iq init --host claude` used to run, doing nothing
  /// the flag implied.
  static const CliContract contract = CliContract.none;

  @override
  Map<String, dynamic> toJson() => {'installDir': installDir};
}

// ─── Steps ──────────────────────────────────────────────────────────────────

/// Removes the agent and skills deployed into every host.
class CleanDeployedHosts implements Step {
  CleanDeployedHosts(this.deployer);

  final HostDeployer deployer;

  @override
  Preview preview() => Preview(
    verb: 'clean',
    target: 'every host this machine deployed to',
    detail: 'the Inquiry agent and its skills',
  );

  @override
  Future<Outcome> perform(StepContext context) async {
    deployer.clean();
    return Outcome(verb: 'clean', target: 'every host this machine deployed to');
  }
}

/// Removes the repository-scoped agent file, when one is there.
class RemoveRepoScopedAgent implements Step {
  RemoveRepoScopedAgent(this.path);

  final String path;

  bool get _exists => File(path).existsSync();

  @override
  Preview preview() => _exists
      ? Preview(verb: 'remove', target: path)
      : Preview(verb: 'absent', target: path);

  @override
  Future<Outcome> perform(StepContext context) async {
    if (!_exists) return Outcome(verb: 'absent', target: path);
    File(path).deleteSync();
    return Outcome(verb: 'remove', target: path);
  }
}

/// Takes the CLI's `bin/` off the user's PATH.
class UnsetFromPath implements Step {
  UnsetFromPath({required this.platformOps, required this.binDir});

  final PlatformOps platformOps;
  final String binDir;

  String get _target => '$binDir from your PATH';

  @override
  Preview preview() => Preview(verb: 'unset', target: _target);

  @override
  Future<Outcome> perform(StepContext context) async {
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
    return Outcome(verb: 'unset', target: _target);
  }

  bool _pathEquals(String a, String b) =>
      p.normalize(a).toLowerCase() == p.normalize(b).toLowerCase();
}

/// Schedules the installation directory for deletion.
///
/// Scheduled rather than done: on Windows the running executable lives inside
/// it and cannot delete itself.
class DeleteInstallation implements Step {
  DeleteInstallation({required this.platformOps, required this.installDir});

  final PlatformOps platformOps;
  final String installDir;

  @override
  Preview preview() => Preview(
    verb: 'delete',
    target: installDir,
    detail: 'your repositories and their cleanrooms are not touched — this '
        'removes the tool, not your work',
  );

  @override
  Future<Outcome> perform(StepContext context) async {
    await platformOps.scheduleDeletion(installDir);
    return Outcome(verb: 'delete', target: installDir);
  }
}

// ─── Output ─────────────────────────────────────────────────────────────────

class UninstallOutput extends Output {
  UninstallOutput({required this.installDir});

  final String installDir;

  @override
  Map<String, dynamic> toJson() => {'installDir': installDir};

  @override
  int get exitCode => ExitCode.ok;

  @override
  String? toText() =>
      'Inquiry uninstalled. Restart your terminal to apply PATH changes.';
}

// ─── Command ────────────────────────────────────────────────────────────────

class UninstallCommand implements Command<UninstallInput, UninstallOutput> {
  @override
  final UninstallInput input;
  final HostDeployer deployer;
  final PlatformOps platformOps;
  final String _workingDirectory;

  UninstallCommand(
    this.input, {
    required this.deployer,
    PlatformOps? platformOps,
    String? workingDirectory,
  }) : platformOps = platformOps ?? PlatformOps.current(),
       _workingDirectory = workingDirectory ?? Directory.current.path;

  @override
  String? validate() => null;

  /// Hosts, then the repository's agent, then PATH, then the directory.
  ///
  /// The order is not cosmetic. PATH is unset before the installation is
  /// scheduled for deletion, so there is never a window in which the entry
  /// points at a directory already on its way out. And the hosts are cleaned
  /// first, while the assets they were deployed from are still there.
  @override
  Future<List<Step>> steps() async => [
    CleanDeployedHosts(deployer),
    RemoveRepoScopedAgent(
      p.join(_workingDirectory, '.github', 'agents', 'inquiry.agent.md'),
    ),
    UnsetFromPath(
      platformOps: platformOps,
      binDir: p.join(input.installDir, 'bin'),
    ),
    DeleteInstallation(
      platformOps: platformOps,
      installDir: input.installDir,
    ),
  ];

  @override
  UninstallOutput describe(Execution execution) =>
      UninstallOutput(installDir: input.installDir);
}
