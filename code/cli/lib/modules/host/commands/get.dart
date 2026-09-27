/// `iq host get [--host <host>] [--configure-ollama]` — installs the Inquiry
/// agent + skills GLOBALLY for a host.
///
/// Additive (#280): other hosts are left untouched, so one machine can serve
/// OpenCode + Claude at once. Global host dirs are isolated → no duplication.
/// `iq init` (repo-scoped) only sets up the cleanroom workspace.
///
/// With no `--host`, every deploy target **detected on this machine** is
/// installed. With `--host`, that one is installed whether or not it looks
/// present, so a fresh setup can be primed before the tool first runs.
///
/// This used to default to `opencode` and assume it (#300), which deployed to a
/// host the user might not have and dragged the OpenCode/Ollama configurator
/// into every `iq upgrade`.
library;

import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';

import '../../../hosts/deployer.dart';
import '../../../hosts/opencode_ollama_configurator.dart';

// ─── Input ──────────────────────────────────────────────────────────────────

class HostGetInput extends Input {
  /// `null` → every detected host.
  final String? host;

  /// Bake `num_ctx` variants of the configured Ollama models (OpenCode only).
  ///
  /// Opt-in: it shells out to `ollama create`, which is slow and blocks when the
  /// daemon is not running. That is an optimization, not part of installing a
  /// CLI.
  final bool configureOllama;

  HostGetInput({this.host, this.configureOllama = false});

  factory HostGetInput.fromCliRequest(CliRequest req) => HostGetInput(
    host: req.flagString('host'),
    configureOllama: req.flagBool('configure-ollama'),
  );

  static final CliContract contract = CliContract(
    options: [
      CliParam.enumeration(
        'host',
        abbr: null,
        required: false,
        repeatable: false,
        values: const ['opencode', 'claude'],
        defaultValue: null,
        description:
            'AI coding host to install into; defaults to every one detected',
      ),
      CliParam.flag(
        'configure-ollama',
        abbr: null,
        repeatable: false,
        description:
            'OpenCode only: bake num_ctx variants of the configured Ollama models',
      ),
    ],
  );

  @override
  Map<String, dynamic> toJson() => {
    'host': host,
    'configureOllama': configureOllama,
  };
}

// ─── Output ─────────────────────────────────────────────────────────────────

class HostGetOutput extends Output {
  HostGetOutput({
    required this.hosts,
    this.retired = const {},
    this.ollamaLines = const [],
    this.supported = const [],
  });

  /// The hosts actually installed into. Empty is a valid outcome: a machine may
  /// carry the CLI and no AI assistant at all.
  final List<String> hosts;

  /// Host → the skills it no longer ships, which the deploy retired.
  final Map<String, List<String>> retired;

  /// What the Ollama configurator had to say, when it ran.
  final List<String> ollamaLines;

  /// Every host this CLI knows how to install into, for the empty case.
  final List<String> supported;

  @override
  Map<String, dynamic> toJson() => {
    'hosts': hosts,
    if (retired.isNotEmpty) 'retired': retired,
    if (ollamaLines.isNotEmpty) 'ollama': ollamaLines,
  };

  /// Deploying to nothing is not a failure — see [hosts].
  @override
  int get exitCode => ExitCode.ok;

  @override
  String? toText() => hosts.isEmpty
      ? 'No AI coding host found on this machine — nothing deployed.\n'
            'Supported: ${supported.join(', ')}.\n'
            'Pass --host <host> to install into one anyway.'
      : [
          for (final host in hosts) ...[
            'Inquiry agent deployed (global) to host $host',
            for (final skill in retired[host] ?? const <String>[])
              '  removed  $skill (from before Inquiry stopped shipping skills)',
          ],
          ...ollamaLines,
        ].join('\n');
}

// ─── Steps ──────────────────────────────────────────────────────────────────

/// Deploys the agent into one host, and sweeps the `iq-` namespace left there
/// by releases that did ship skills.
///
/// One step per host, so the plan names each of them: deploying to two
/// assistants and deploying to none look nothing alike, and a single line
/// saying "deploy hosts" would hide the difference.
class DeployToHost implements Step {
  DeployToHost({required this.deployer, required this.host});

  final HostDeployer deployer;
  final String host;

  @override
  Preview preview() => Preview(
    verb: 'deploy',
    target: 'host $host',
    detail:
        'the Inquiry agent and its skills, globally; skills no longer '
        'shipped are retired',
  );

  @override
  Future<Outcome> perform(StepContext context) async {
    final retired = deployer.deploy(host);
    return Outcome(
      verb: 'deploy',
      target: 'host $host',
      values: {'host': host, 'retired': retired},
    );
  }
}

/// Bakes `num_ctx` variants of the configured Ollama models.
///
/// Opt-in behind `--configure-ollama`: it shells out to `ollama create`, which
/// is slow and blocks when the daemon is not running. That is an optimization,
/// not part of installing a CLI — which is exactly why it is a step of its own
/// and named in the plan.
class ConfigureOllama implements Step {
  ConfigureOllama(this.configurator);

  final OpenCodeOllamaConfigurator configurator;

  @override
  Preview preview() => Preview(
    verb: 'configure',
    target: 'the Ollama models OpenCode uses',
    detail:
        'bakes num_ctx variants — shells out to `ollama create`, which is '
        'slow and needs the daemon running',
  );

  @override
  Future<Outcome> perform(StepContext context) async {
    final lines = await configurator.configure();
    return Outcome(
      verb: 'configure',
      target: 'the Ollama models OpenCode uses',
      values: {'lines': lines},
    );
  }
}

// ─── Command ────────────────────────────────────────────────────────────────

/// What `host get` says when this machine carries no AI coding host.
///
/// One wording, reached two ways: as the reason an empty plan gives, and as
/// [HostGetOutput.toText] for a run that produced no deploy. Written once so
/// the two cannot drift.
String noHostFoundMessage(List<String> supported) =>
    'No AI coding host found on this machine — nothing deployed.\n'
    'Supported: ${supported.join(', ')}.\n'
    'Pass --host <host> to install into one anyway.';

class HostGetCommand
    implements Command<HostGetInput, HostGetOutput>, ExplainsNothingToDo {
  @override
  final HostGetInput input;
  final HostDeployer deployer;

  /// OpenCode-only: ensures the configured Ollama models have an adequate
  /// `num_ctx` (bakes variants + rewrites opencode.jsonc). Null disables it.
  final OpenCodeOllamaConfigurator? configurator;

  HostGetCommand(this.input, {required this.deployer, this.configurator});

  /// A machine with no AI assistant is an answer, not a failure — and the
  /// answer says which hosts exist and how to install one anyway.
  @override
  String? get nothingToDo =>
      noHostFoundMessage(deployer.adapters.map((a) => a.name).toList());

  @override
  String? validate() {
    if (input.host == null) return null;
    final validNames = deployer.adapters.map((a) => a.name).toSet();
    if (!validNames.contains(input.host)) {
      return 'Unknown host: "${input.host}". '
          'Valid hosts: ${validNames.join(", ")}';
    }
    return null;
  }

  /// One step per host, and the Ollama configuration after the host it belongs
  /// to.
  ///
  /// Deploying to nothing builds no steps: a machine may carry the CLI and no
  /// AI assistant at all, and that is an answer rather than a failure.
  @override
  Future<List<Step>> steps() async {
    final targets = input.host != null
        ? [input.host!]
        : deployer.detectedHosts.map((a) => a.name).toList();

    return [
      for (final host in targets) ...[
        DeployToHost(deployer: deployer, host: host),
        if (host == 'opencode' && input.configureOllama && configurator != null)
          ConfigureOllama(configurator!),
      ],
    ];
  }

  @override
  HostGetOutput describe(Execution execution) => HostGetOutput(
    hosts: [
      for (final o in execution.outcomes)
        if (o.verb == 'deploy') o.values['host'] as String,
    ],
    retired: {
      for (final o in execution.outcomes)
        if (o.verb == 'deploy')
          o.values['host'] as String: (o.values['retired'] as List)
              .cast<String>(),
    },
    ollamaLines: [
      for (final o in execution.outcomes)
        if (o.verb == 'configure')
          ...(o.values['lines'] as List).cast<String>(),
    ],
    supported: deployer.adapters.map((a) => a.name).toList(),
  );
}
