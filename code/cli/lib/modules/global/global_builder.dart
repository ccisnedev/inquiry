// `UpgradeInput`/`UpgradeOutput`/`UpgradeCommand` and their `Uninstall*`
// counterparts are hidden: `modular_cli_sdk` re-exports its own
// `InstallationPlugin`'s classes of the same names, which this CLI does not
// use (see `commands/upgrade.dart` / `commands/uninstall.dart` for Inquiry's
// own, unrelated implementations).
import 'package:modular_cli_sdk/modular_cli_sdk.dart'
    hide
        UpgradeInput,
        UpgradeOutput,
        UpgradeCommand,
        UninstallInput,
        UninstallOutput,
        UninstallCommand;

import '../../assets.dart';
import '../../hosts/deployer.dart';
import 'commands/init.dart';
import 'commands/tui.dart';
import 'commands/uninstall.dart';
import 'commands/upgrade.dart';

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
void buildGlobalModule(
  ModuleBuilder m, {
  required HostDeployer cleaner,
  Assets? assets,
}) {
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

  m.command<UpgradeInput, UpgradeOutput>(
    'upgrade',
    (req) => UpgradeCommand(UpgradeInput.fromCliRequest(req)),
    description: 'Download and install the latest Inquiry release',
    globals: true,
    contract: UpgradeInput.contract,
  );

  m.command<UninstallInput, UninstallOutput>(
    'uninstall',
    (req) =>
        UninstallCommand(UninstallInput.fromCliRequest(req), deployer: cleaner),
    description: 'Remove Inquiry CLI from the system',
    globals: true,
    contract: UninstallInput.contract,
  );
}
