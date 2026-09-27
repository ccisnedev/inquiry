/// `iq host clean` — removes deployed Inquiry files from all hosts.
library;

import 'dart:io';

import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:path/path.dart' as p;

import '../../../src/git_utils.dart';
import '../../../hosts/deployer.dart';

// ─── Input ──────────────────────────────────────────────────────────────────

class HostCleanInput extends Input {
  HostCleanInput();

  factory HostCleanInput.fromCliRequest(CliRequest req) => HostCleanInput();

  /// Declares an EMPTY contract: this command accepts no option at all, so any
  /// option passed to it is refused. Omitting `contract` would mean "declares
  /// nothing" — which is how `iq init --host claude` used to run, doing nothing
  /// the flag implied.
  static const CliContract contract = CliContract.none;

  @override
  Map<String, dynamic> toJson() => {};
}

// ─── Output ─────────────────────────────────────────────────────────────────

class HostCleanOutput extends Output {
  HostCleanOutput({required this.removedRepoAgent});

  /// Whether a repository-scoped agent file was there to remove.
  final bool removedRepoAgent;

  @override
  Map<String, dynamic> toJson() => {'removedRepoAgent': removedRepoAgent};

  @override
  int get exitCode => ExitCode.ok;

  @override
  String? toText() => [
    'Inquiry cleaned from all hosts',
    if (removedRepoAgent) '  removed the repository-scoped agent too',
  ].join('\n');
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
    return Outcome(
      verb: 'clean',
      target: 'every host this machine deployed to',
    );
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

// ─── Command ────────────────────────────────────────────────────────────────

class HostCleanCommand implements Command<HostCleanInput, HostCleanOutput> {
  @override
  final HostCleanInput input;
  final HostDeployer deployer;
  final String _workingDirectory;

  HostCleanCommand(
    this.input, {
    required this.deployer,
    String? workingDirectory,
  }) : _workingDirectory = workingDirectory ?? Directory.current.path;

  @override
  String? validate() => null;

  @override
  Future<List<Step>> steps() async {
    final projectRoot = getProjectRoot(_workingDirectory) ?? _workingDirectory;
    return [
      CleanDeployedHosts(deployer),
      RemoveRepoScopedAgent(
        p.join(projectRoot, '.github', 'agents', 'inquiry.agent.md'),
      ),
    ];
  }

  @override
  HostCleanOutput describe(Execution execution) => HostCleanOutput(
    removedRepoAgent: execution.outcomes.any((o) => o.verb == 'remove'),
  );
}
