/// `inquiry init` — sets up the Inquiry workspace in the current repo.
///
/// Repo-scoped, idempotent steps:
/// 1. Create cleanrooms/ at project root if missing
/// 2. Add .inquiry/ and cleanrooms/**/.iq.state.yaml to .gitignore
/// 3. Create .inquiry/config.yaml with defaults
///
/// The inquiry agent is installed GLOBALLY per host by
/// `iq host get --host <host>` (#280) — NOT here. Cycle runtime
/// (`.iq.state.yaml`, `mutations.md`) is materialized per cycle under
/// `cleanrooms/<branch>/` by the FSM, not scaffolded at init.
library;

import 'dart:io';

import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:path/path.dart' as p;

import '../../../src/git_utils.dart';
import '../../../src/gitignore.dart';

// ─── Input ──────────────────────────────────────────────────────────────────

/// Carries the working directory where the workspace will be initialized.
class InitInput extends Input {
  final String workingDirectory;

  InitInput({required this.workingDirectory});

  factory InitInput.fromCliRequest(CliRequest req) =>
      InitInput(workingDirectory: Directory.current.path);

  /// Declares an EMPTY contract: this command accepts no option at all, so any
  /// option passed to it is refused. Omitting `contract` would mean "declares
  /// nothing" — which is how `iq init --host claude` used to run, doing nothing
  /// the flag implied.
  static const CliContract contract = CliContract.none;

  @override
  Map<String, dynamic> toJson() => {'workingDirectory': workingDirectory};
}

// ─── Output ─────────────────────────────────────────────────────────────────

class InitOutput extends Output {
  final String message;
  final bool isCreated;

  InitOutput({required this.message, required this.isCreated});

  @override
  Map<String, dynamic> toJson() => {'message': message, 'created': isCreated};

  @override
  int get exitCode => ExitCode.ok;
}

// ─── Command ────────────────────────────────────────────────────────────────

/// Sets up the repo workspace (cleanrooms + .inquiry). Idempotent.
class InitCommand implements Query<InitInput, InitOutput> {
  @override
  final InitInput input;

  InitCommand(this.input);

  @override
  String? validate() => null;

  @override
  Future<InitOutput> execute() async {
    final root = _resolveProjectRoot(input.workingDirectory);
    final steps = <String>[];

    // Step 1: Create cleanrooms/ at project root if missing
    final issuesDir = Directory('$root/cleanrooms');
    if (!issuesDir.existsSync()) {
      issuesDir.createSync(recursive: true);
      steps.add('Created ${_relative(root, issuesDir.path)}');
    }

    // Step 2: Add .inquiry/ and cycle-local state to .gitignore
    _ensureGitignore(root, steps);

    // Step 3: Create .inquiry/config.yaml with defaults
    _ensureConfigYaml(root, steps);

    if (steps.isEmpty) {
      return InitOutput(
        message: 'Inquiry already initialized in $root',
        isCreated: false,
      );
    }

    return InitOutput(message: steps.join('\n'), isCreated: true);
  }

  String _resolveProjectRoot(String workingDirectory) =>
      getProjectRoot(workingDirectory) ?? workingDirectory;

  /// Ensures `.inquiry/`, cycle-local state, and `docs/requisitions/` are in
  /// `.gitignore` (via the shared helper).
  void _ensureGitignore(String root, List<String> steps) {
    final status = ensureGitignoreEntries(root);
    if (status != null) steps.add(status);
  }

  /// Ensures `.inquiry/config.yaml` exists with default configuration.
  void _ensureConfigYaml(String root, List<String> steps) {
    final configDir = Directory('$root/.inquiry');
    final configFile = File('$root/.inquiry/config.yaml');

    if (!configFile.existsSync()) {
      if (!configDir.existsSync()) configDir.createSync(recursive: true);
      configFile.writeAsStringSync(
        'evolution:\n'
        '  enabled: false\n',
      );
      steps.add('Created .inquiry/config.yaml');
    }
  }

  String _relative(String root, String path) => p.relative(path, from: root);
}
