/// Inquiry's own doctor checks — prerequisites and host deployment.
///
/// Checks: inquiry version, git, gh, gh auth, .inquiry/ init, internal assets,
/// update availability, per-host deployment, OpenCode/Ollama context.
///
/// These are contributed to `modular_cli_sdk`'s `DoctorPlugin` extension
/// point (`DoctorPlugin.extensionPoint`, `'doctor.checks'`) by
/// [InquiryDoctorChecksPlugin] in `doctor_checks_plugin.dart`, rather than
/// registering a `doctor` route of Inquiry's own (ccisnedev/inquiry#321).
///
/// **`--fix` is deliberately not ported.** The old `DoctorCommand` could
/// download and extract missing assets in place when called with `--fix`.
/// `DoctorPlugin`'s own `doctor` route always builds a parameterless
/// `DoctorInput` (`toJson() => const {}`), and a contributed
/// `CliDoctorCheck.run` takes no arguments either: there is no path left for
/// a per-invocation flag to reach a check. `iq upgrade --apply` covers the
/// same ground now — `refreshAssetsAfterUpgrade` (in `commands/upgrade.dart`)
/// downloads the release archive again and replaces `assets/` wholesale, even
/// when the binary itself is already current, so it doubles as a repair tool.
library;

import 'dart:io';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:path/path.dart' as p;

import '../../../assets.dart';
import '../../../src/version.dart' as version_lib;
import '../../../src/version_check.dart';
import '../../../hosts/all_adapters.dart';
import '../../../hosts/host_adapter.dart';
import '../../../hosts/ollama_context.dart';

/// Function type for running external processes.
///
/// Allows injection of a mock for testing.
typedef ProcessRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    });

/// Result of checking a host's deployment status.
class HostCheck {
  final String hostName;
  final bool agentExists;
  final List<String> missingSkills;
  final int totalSkills;
  final String? error;

  /// Whether this host is the active/deployed one (its skills are present).
  /// Under the exclusive deploy model exactly one host is active at a time; an
  /// inactive host is not a failure (it was simply not the chosen host).
  final bool active;

  /// Whether the host tool itself is present on this machine.
  ///
  /// `iq host get` only deploys to hosts that are installed, so "not installed"
  /// is the reason an absent deployment is fine — and reporting it here is what
  /// makes that legible instead of looking like a missing step (#300).
  final bool installed;

  HostCheck({
    required this.hostName,
    required this.agentExists,
    required this.missingSkills,
    required this.totalSkills,
    this.error,
    this.active = true,
    this.installed = true,
  });

  /// A host that is not installed, or not the active one, never fails the
  /// doctor. An active, installed host must be complete.
  bool get passed =>
      !installed ||
      !active ||
      (agentExists && missingSkills.isEmpty && error == null);

  Map<String, dynamic> toJson() => {
    'hostName': hostName,
    'agentExists': agentExists,
    'missingSkills': missingSkills,
    'totalSkills': totalSkills,
    'active': active,
    'installed': installed,
    if (error != null) 'error': error,
  };
}

/// Abstraction for filesystem operations (testable).
abstract class FileSystemOps {
  bool fileExists(String path);
  bool directoryExists(String path);
  String homeDirectory();

  /// Reads a text file, or returns null if it does not exist.
  String? readFile(String path);
}

/// Production implementation using dart:io.
class RealFileSystemOps implements FileSystemOps {
  @override
  bool fileExists(String path) => File(path).existsSync();

  @override
  bool directoryExists(String path) => Directory(path).existsSync();

  @override
  String homeDirectory() {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) return home;
    return Directory.current.path;
  }

  @override
  String? readFile(String path) {
    final f = File(path);
    return f.existsSync() ? f.readAsStringSync() : null;
  }
}

/// Inquiry's own prerequisite and host-deployment checks, each exposed as a
/// method returning a [CliCheckResult] so [InquiryDoctorChecksPlugin] can
/// contribute them independently to `doctor.checks`.
///
/// Every check here runs on its own: unlike the old `DoctorCommand.execute()`,
/// there is no early return on a failing `git`/`gh` check — `DoctorQuery`
/// (in `modular_cli_sdk`) runs every contributed check unconditionally, which
/// is more informative (a missing `gh` no longer hides whether `git` is also
/// missing) at the cost of that early-exit behavior.
class InquiryDoctorChecks {
  final ProcessRunner _runProcess;
  final FileSystemOps _fileSystem;
  final Assets? _assets;
  final List<HostAdapter> activeAdapters;
  final Future<VersionCheckResult> Function({required String currentVersion})?
  _versionChecker;

  /// Current Inquiry version (injected for testability).
  final String inquiryVersion;

  InquiryDoctorChecks({
    ProcessRunner? runProcess,
    String? inquiryVersionOverride,
    FileSystemOps? fileSystemOps,
    Assets? assets,
    List<HostAdapter>? activeAdapters,
    Future<VersionCheckResult> Function({required String currentVersion})?
    versionChecker,
  }) : _runProcess = runProcess ?? Process.run,
       _fileSystem = fileSystemOps ?? RealFileSystemOps(),
       _assets = assets,
       activeAdapters = activeAdapters ?? deployAdapters,
       _versionChecker = versionChecker,
       inquiryVersion = inquiryVersionOverride ?? version_lib.inquiryVersion;

  Future<CliCheckResult> checkInquiryVersion() async =>
      CliCheckResult(status: CliCheckStatus.ok, message: inquiryVersion);

  Future<CliCheckResult> checkGit() => _checkCommand(
    executable: 'git',
    arguments: ['--version'],
    versionExtractor: _extractGitVersion,
  );

  Future<CliCheckResult> checkGh() => _checkCommand(
    executable: 'gh',
    arguments: ['--version'],
    versionExtractor: _extractGhVersion,
  );

  Future<CliCheckResult> checkGhAuth() => _checkCommand(
    executable: 'gh',
    arguments: ['auth', 'status'],
    versionExtractor: (_) => null,
  );

  Future<CliCheckResult> checkInit() async {
    if (_fileSystem.directoryExists('.inquiry')) {
      return const CliCheckResult(
        status: CliCheckStatus.ok,
        message: 'initialized',
      );
    }
    return const CliCheckResult(
      status: CliCheckStatus.error,
      message: "not initialized. Run 'inquiry init' to initialize",
    );
  }

  /// Checks that all expected internal assets exist on disk.
  ///
  /// `ok` with an explanatory message when there is no [Assets] to verify
  /// against (cannot verify, not a failure).
  Future<CliCheckResult> checkAssets() async {
    final assets = _assets;
    if (assets == null) {
      return const CliCheckResult(
        status: CliCheckStatus.ok,
        message: 'not checked (no asset root configured)',
      );
    }

    final missing = <String>[];

    // FSM state instruction files
    const stateFiles = [
      'idle',
      'analyze',
      'plan',
      'execute',
      'end',
      'evolution',
    ];
    for (final state in stateFiles) {
      final path = assets.path('fsm/states/$state.yaml');
      if (!File(path).existsSync()) {
        missing.add('fsm/states/$state.yaml');
      }
    }

    // APE definition files
    const apeFiles = ['socrates', 'dewey', 'descartes', 'ada', 'darwin'];
    for (final ape in apeFiles) {
      final path = assets.path('apes/$ape.yaml');
      if (!File(path).existsSync()) {
        missing.add('apes/$ape.yaml');
      }
    }

    // Transition contract
    final contractPath = assets.path('fsm/transition_contract.yaml');
    if (!File(contractPath).existsSync()) {
      missing.add('fsm/transition_contract.yaml');
    }

    // Skills
    try {
      final skills = assets.listDirectory('skills');
      for (final skill in skills) {
        final path = assets.path('skills/$skill/SKILL.md');
        if (!File(path).existsSync()) {
          missing.add('skills/$skill/SKILL.md');
        }
      }
    } catch (_) {
      missing.add('skills/ (directory missing)');
    }

    if (missing.isEmpty) {
      return const CliCheckResult(status: CliCheckStatus.ok, message: 'ok');
    }

    return CliCheckResult(
      status: CliCheckStatus.error,
      message:
          '${missing.length} missing: ${missing.join(', ')}. '
          "Run 'iq upgrade --apply' to restore them",
    );
  }

  /// Checks if a newer version is available. Never fails `doctor`: reported
  /// as [CliCheckStatus.warning] at most, matching the old check's
  /// non-blocking behavior.
  Future<CliCheckResult> checkUpdate() async {
    try {
      final checker =
          _versionChecker ??
          ({required String currentVersion}) =>
              checkLatestVersion(currentVersion: currentVersion);
      final result = await checker(currentVersion: inquiryVersion);
      if (result.updateAvailable && result.latestVersion != null) {
        return CliCheckResult(
          status: CliCheckStatus.warning,
          message:
              "${result.latestVersion} available. Run 'iq upgrade --apply' "
              'to update',
        );
      }
      return const CliCheckResult(
        status: CliCheckStatus.ok,
        message: 'up to date',
      );
    } on Object catch (e) {
      return CliCheckResult(
        status: CliCheckStatus.warning,
        message: 'could not check for updates: $e',
      );
    }
  }

  /// The skills a deployed host is expected to carry.
  ///
  /// **Empty, and that is the answer now.** Inquiry ships no skills: the
  /// lifecycle four went to MACSS, and `kritik`, `legion` and `research` — which
  /// were transversal and belonged to no single project — ship with
  /// `skillwire_cli`. What is deployed on this machine, by whom, and whether it
  /// has drifted is `iq skill doctor`'s question, over the shared ledger.
  ///
  /// The method stays because the asset tree may carry skills again, and a host
  /// check that silently ignored them would be worse than one that finds none.
  List<String> _getExpectedSkills() {
    final assets = _assets;
    if (assets == null) return [];
    try {
      return assets.listDirectory('skills');
    } catch (_) {
      return [];
    }
  }

  /// Verifies a single host adapter's deployment.
  HostCheck verifyHost(HostAdapter adapter) {
    final homeDir = _fileSystem.homeDirectory();
    final expectedSkills = _getExpectedSkills();
    final installed = _fileSystem.directoryExists(
      adapter.baseDirectory(homeDir),
    );

    // Agent + skills are installed GLOBALLY per host by `iq host get` (#280).
    final agentExists = _fileSystem.fileExists(
      p.join(adapter.agentDirectory(homeDir), 'inquiry.md'),
    );

    // Check skills — adapter-scoped
    final missingSkills = <String>[];
    for (final skill in expectedSkills) {
      final skillPath = p.join(
        adapter.skillsDirectory(homeDir),
        skill,
        'SKILL.md',
      );
      if (!_fileSystem.fileExists(skillPath)) {
        missingSkills.add(skill);
      }
    }

    // Active = this host's skills are deployed. Under the exclusive deploy
    // model exactly one host is active; with no expected skills (assets
    // unavailable) fall back to agent presence.
    final active = expectedSkills.isEmpty
        ? agentExists
        : missingSkills.length < expectedSkills.length;

    return HostCheck(
      hostName: adapter.name,
      agentExists: agentExists,
      missingSkills: missingSkills,
      totalSkills: expectedSkills.length,
      active: active,
      installed: installed,
    );
  }

  /// Reports [adapter]'s own deployment status. Never a failure on its own
  /// when the host is simply absent or inactive — see [HostCheck.passed].
  Future<CliCheckResult> checkHost(HostAdapter adapter) async {
    final hc = verifyHost(adapter);
    if (!hc.installed) {
      return const CliCheckResult(
        status: CliCheckStatus.ok,
        message: 'not installed',
      );
    }
    if (!hc.active) {
      return const CliCheckResult(
        status: CliCheckStatus.ok,
        message: 'not deployed (inactive)',
      );
    }
    if (hc.passed) {
      return const CliCheckResult(
        status: CliCheckStatus.ok,
        message: 'agent deployed',
      );
    }

    final problems = <String>[];
    if (!hc.agentExists) {
      problems.add(
        'agent not deployed. '
        "Run 'iq host get --host ${adapter.name} --apply' to install it",
      );
    }
    if (hc.missingSkills.isNotEmpty) {
      problems.add(
        'missing skills: ${hc.missingSkills.join(', ')}. '
        "Run 'iq host get --host ${adapter.name} --apply' to deploy them",
      );
    }
    return CliCheckResult(
      status: CliCheckStatus.error,
      message: problems.join('; '),
    );
  }

  /// At least one host must be active (deployed) on a machine that has any AI
  /// coding host installed at all; a machine with none installed is a
  /// legitimate state, not a failure (#300).
  Future<CliCheckResult> checkAnyHostActive() async {
    final checks = activeAdapters.map(verifyHost).toList(growable: false);
    if (!checks.any((hc) => hc.installed)) {
      return const CliCheckResult(
        status: CliCheckStatus.ok,
        message: 'no AI coding host installed on this machine',
      );
    }
    if (!checks.any((hc) => hc.active)) {
      return const CliCheckResult(
        status: CliCheckStatus.error,
        message: "no host deployed. Run 'iq host get --apply'",
      );
    }
    return CliCheckResult(
      status: CliCheckStatus.ok,
      message: checks
          .where((hc) => hc.active)
          .map((hc) => hc.hostName)
          .join(', '),
    );
  }

  /// Verifies every Ollama model configured for OpenCode has an effective
  /// `num_ctx >= kInquiryMinNumCtx`. `ok` ("not applicable") when OpenCode is
  /// not the active host, there is no config, or no Ollama provider — this
  /// check always runs (contributed checks cannot be conditional at setup
  /// time), so the "nothing to verify" cases must be reported as `ok` rather
  /// than omitted, unlike the old `DoctorCommand`'s optional check.
  Future<CliCheckResult> checkOllamaContext() async {
    final opencodeActive = activeAdapters
        .map(verifyHost)
        .any((hc) => hc.hostName == 'opencode' && hc.active);
    if (!opencodeActive) {
      return const CliCheckResult(
        status: CliCheckStatus.ok,
        message: 'not applicable (OpenCode is not the active host)',
      );
    }

    final cfgPath = p.join(
      _fileSystem.homeDirectory(),
      '.config',
      'opencode',
      'opencode.jsonc',
    );
    final raw = _fileSystem.readFile(cfgPath);
    if (raw == null) {
      return const CliCheckResult(
        status: CliCheckStatus.ok,
        message: 'not applicable (no opencode.jsonc)',
      );
    }

    final models = ollamaModelsFromConfig(raw);
    if (models.isEmpty) {
      return const CliCheckResult(
        status: CliCheckStatus.ok,
        message: 'not applicable (no Ollama provider configured)',
      );
    }

    final tooSmall = <String>[];
    for (final model in models) {
      final ctx = await effectiveNumCtx(_runProcess, model);
      if (ctx == null) continue; // can't determine (Ollama absent) — skip
      if (ctx < kInquiryMinNumCtx) tooSmall.add('$model (num_ctx=$ctx)');
    }
    if (tooSmall.isEmpty) {
      return const CliCheckResult(status: CliCheckStatus.ok, message: 'ok');
    }

    return CliCheckResult(
      status: CliCheckStatus.error,
      message:
          'num_ctx < $kInquiryMinNumCtx for: ${tooSmall.join(', ')}. '
          "Inquiry's prompt needs ~8K tokens; at 4096 it is truncated and the "
          "harness fails silently. Bake a variant — Modelfile 'FROM <model>\\n"
          "PARAMETER num_ctx 16384' then 'ollama create <model>-16k -f Modelfile' "
          "(32768 recommended) — and point opencode.jsonc at it. "
          "Or run 'iq host get --host opencode --configure-ollama --apply' to configure it.",
    );
  }

  /// Runs a command and returns a [CliCheckResult] with the result.
  Future<CliCheckResult> _checkCommand({
    required String executable,
    required List<String> arguments,
    required String? Function(String stdout) versionExtractor,
  }) async {
    try {
      final result = await _runProcess(executable, arguments);
      if (result.exitCode == 0) {
        final version = versionExtractor(result.stdout.toString());
        return CliCheckResult(
          status: CliCheckStatus.ok,
          message: version ?? 'ok',
        );
      } else {
        return CliCheckResult(
          status: CliCheckStatus.error,
          message: result.stderr.toString().trim(),
        );
      }
    } catch (e) {
      return CliCheckResult(status: CliCheckStatus.error, message: '$e');
    }
  }

  /// Extracts version from "git version X.Y.Z".
  String? _extractGitVersion(String stdout) {
    final match = RegExp(r'git version (\d+\.\d+\.\d+)').firstMatch(stdout);
    return match?.group(1);
  }

  /// Extracts version from "gh version X.Y.Z (...)".
  String? _extractGhVersion(String stdout) {
    final match = RegExp(r'gh version (\d+\.\d+\.\d+)').firstMatch(stdout);
    return match?.group(1);
  }
}
