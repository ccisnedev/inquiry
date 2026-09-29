/// Public API for the `inquiry` CLI.
///
/// [runInquiry] is the single entry point — called by `bin/main.dart` and by tests.
library;

import 'dart:io';

import 'package:datajack/datajack.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:skillwire/skillwire.dart';
import 'package:path/path.dart' as p;

import 'assets.dart';
import 'modules/global/global_builder.dart';
import 'modules/global/commands/doctor.dart';
import 'modules/global/doctor_checks_plugin.dart';
import 'modules/global/installation_config.dart';
import 'modules/fsm/fsm_builder.dart';
import 'modules/ape/ape_builder.dart';
import 'modules/implementation/implementation_builder.dart';
import 'modules/host/host_builder.dart';
import 'hosts/all_adapters.dart';
import 'hosts/deployer.dart';
import 'src/version.dart';

/// The name this CLI writes into every ledger row it creates, and the name the
/// other consumers see when they meet one of its artifacts.
const inquiryConsumerName = 'inquiry';

/// `--help` / `-h` are NOT normalized here: the SDK routes every help request
/// itself, including the focused `iq <command> --help`, which this could not.
List<String> normalizeInquiryArgs(List<String> args) {
  if (args.length == 1 && (args.first == '--version' || args.first == '-v')) {
    return const ['version'];
  }
  return args;
}

/// Configures the CLI, registers all commands, and dispatches [args].
///
/// Returns a process exit code. [stdout] / [stderr] default to the process
/// streams; tests pass their own sinks to assert on what the user actually sees.
Future<int> runInquiry(
  List<String> args, {
  IOSink? stdout,
  IOSink? stderr,
  Map<String, String>? environment,
}) async {
  final assetsRoot = p.dirname(p.dirname(Platform.resolvedExecutable));
  final assets = Assets(root: assetsRoot);

  final deployer = HostDeployer(
    assets: Assets(root: assetsRoot),
    adapters: deployAdapters,
    homeDir:
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '',
  );

  final cleaner = HostDeployer(
    assets: Assets(root: assetsRoot),
    adapters: allAdapters,
    homeDir:
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '',
  );

  final cli =
      ModularCli(
          name: 'inquiry',
          version: inquiryVersion,
          suggestionDistance: 2,
        )
        ..plugin(VersionPlugin(version: inquiryVersion))
        ..plugin(const DoctorPlugin())
        ..plugin(
          InquiryDoctorChecksPlugin(
            checks: InquiryDoctorChecks(assets: assets),
          ),
        )
        ..plugin(
          InstallationPlugin(
            config: inquiryInstallationConfig(
              cleaner: cleaner,
              repoScopedAgentPath: p.join(
                Directory.current.path,
                '.github',
                'agents',
                'inquiry.agent.md',
              ),
            ),
          ),
        );

  cli.module('', (m) => buildGlobalModule(m, assets: assets));
  cli.module(
    'host',
    (m) => buildHostModule(m, deployer: deployer, cleaner: cleaner),
  );
  // R12.1 — the same `skill` module the other consumers mount, from `datajack`.
  // Inquiry ships no skills of its own, so `deploy` has nothing to carry; what
  // it gains is `doctor`, `list` and `validate` over the shared ledger, which
  // is what a user on a machine that also runs `macss` actually needs.
  final skillWorkspace = Workspace.detect();
  cli.module(
    'skill',
    (m) => buildSkillModule(
      m,
      consumer: inquiryConsumerName,
      workspace: skillWorkspace,
      catalogue: Catalogue.read(
        skillWorkspace.assetsRoot,
        validator: SkillValidator(
          reservedNames: skillWorkspace.matrix.reservedNames,
        ),
      ),
    ),
  );
  cli.module('fsm', (m) => buildFsmModule(m, assets: assets));
  cli.module('ape', (m) => buildApeModule(m, assets: assets));
  cli.module(
    'implementation',
    (m) => buildImplementationModule(m, assets: assets),
  );

  return cli.run(
    normalizeInquiryArgs(args),
    stdout: stdout,
    stderr: stderr,
    environment: environment,
  );
}
