import 'package:modular_cli_sdk/modular_cli_sdk.dart';

import '../../assets.dart';
import 'commands/init.dart';
import 'commands/tui.dart';

/// `help` is not registered here: `modular_cli_sdk` renders it from the command
/// catalog these registrations feed, so a command cannot ship without appearing
/// in it. Inquiry's own hand-written help had already drifted — the
/// `specification` and `issue` modules were absent from it for two releases.
///
/// `version` and `doctor` are registered by `modular_cli_sdk`'s own
/// `VersionPlugin` and `DoctorPlugin`, not here. Inquiry's own doctor checks
/// are contributed to `DoctorPlugin.extensionPoint` by
/// `InquiryDoctorChecksPlugin` (see `doctor_checks_plugin.dart`), not
/// registered as a route of their own — a second `doctor` route here would
/// collide with `DoctorPlugin`'s (`PLUGIN_DUPLICATE_ROUTE`).
///
/// `upgrade` and `uninstall` are likewise not registered here: `modular_cli_sdk`'s
/// `InstallationPlugin` registers both globally itself (see
/// `inquiry_cli.dart`), with inquiry's own extra steps
/// (`commands/upgrade.dart`'s `RedeployHosts`, `commands/uninstall.dart`'s
/// `CleanDeployedHosts` / `RemoveRepoScopedAgent`) supplied through
/// `CliInstallationConfig.postUpgradeSteps` / `preUninstallSteps`. A second
/// `upgrade` or `uninstall` route here would collide with the plugin's
/// (`PLUGIN_DUPLICATE_ROUTE`).
void buildGlobalModule(ModuleBuilder m, {Assets? assets}) {
  m.query<TuiInput, TuiOutput>(
    '',
    (req) => TuiCommand(TuiInput.fromCliRequest(req)),
    description: 'Display Inquiry status and FSM diagram',
    globals: true,
    contract: TuiInput.contract,
  );

  m.query<InitInput, InitOutput>(
    'init',
    (req) => InitCommand(InitInput.fromCliRequest(req)),
    description:
        'Set up the Inquiry workspace in this repo (cleanrooms + .inquiry). Install a host first with `iq host get --apply`.',
    globals: true,
    contract: InitInput.contract,
  );
}
