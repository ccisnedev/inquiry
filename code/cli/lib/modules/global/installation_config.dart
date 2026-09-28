/// The `CliInstallationConfig` inquiry hands to `modular_cli_sdk`'s
/// `InstallationPlugin` for `iq upgrade` / `iq uninstall`.
///
/// Kept in its own file, separate from `inquiry_cli.dart`, so it can be
/// built and inspected directly by tests without spinning up the whole CLI.
/// See `docs/installation-parity.md` in `modular_cli_sdk` for what every
/// field here means and why (the inquiry column there is the source of
/// truth this config reproduces).
library;

import 'package:modular_cli_sdk/modular_cli_sdk.dart';

import '../../hosts/deployer.dart';
import 'commands/uninstall.dart';
import 'commands/upgrade.dart';

/// What `RedeployHosts` runs the freshly installed binary with, matching
/// what `code/site/install.ps1` runs right after installing: the redeploy
/// carries the approval the upgrade itself already took, since the child has
/// no terminal to be asked on.
const inquiryPostInstallArguments = ['host', 'get', '--apply', '--autoapprove'];

/// Builds the config inquiry hands to [InstallationPlugin].
///
/// `verifyAfterInstall: false`: the plugin's own inline verification (the
/// default, matching macss) is hard-fail and runs [inquiryPostInstallArguments]
/// synchronously right after extraction. Inquiry's own post-install check is
/// [RedeployHosts] instead, supplied through [postUpgradeSteps] below: best
/// effort, and it must never fail the upgrade over it (#300). Turning the
/// hard-fail check off is what stops the two from running twice, back to
/// back, with the same arguments.
CliInstallationConfig inquiryInstallationConfig({
  required HostDeployer cleaner,
  required String repoScopedAgentPath,
}) => CliInstallationConfig(
  repository: 'ccisnedev/inquiry',
  executable: 'inquiry',
  alias: 'iq',
  assets: const {
    'windows': 'inquiry-windows-x64.zip',
    'linux': 'inquiry-linux-x64.tar.gz',
  },
  postInstallArguments: inquiryPostInstallArguments,
  verifyAfterInstall: false,
  postUpgradeSteps: (installDir, platformOps) => [
    RedeployHosts(platformOps: platformOps, installDir: installDir),
  ],
  preUninstallSteps: (installDir, platformOps) => [
    CleanDeployedHosts(cleaner),
    RemoveRepoScopedAgent(repoScopedAgentPath),
  ],
);
