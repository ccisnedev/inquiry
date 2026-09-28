/// Inquiry's own extra steps for `iq uninstall`, supplied to the SDK's
/// `InstallationPlugin` via `CliInstallationConfig.preUninstallSteps`.
///
/// Taking `bin/` off PATH and scheduling the install directory for deletion
/// are both handled by the plugin's own `UninstallCommand` now
/// (`package:modular_cli_sdk`). What is left here is what inquiry adds
/// before that: cleaning every host it deployed to, and removing the
/// repository-scoped agent file, while the assets they were deployed from
/// are still there.
library;

import 'dart:io';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';

import '../../../hosts/deployer.dart';

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
