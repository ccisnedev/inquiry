/// Contributes Inquiry's own prerequisite and host-deployment checks to
/// `modular_cli_sdk`'s `DoctorPlugin` extension point (ccisnedev/inquiry#321).
///
/// `DoctorPlugin` itself owns the `doctor` route and contributes no checks —
/// see its own doc comment. This plugin is what makes `iq doctor` report
/// anything at all for Inquiry.
library;

import 'package:modular_cli_sdk/modular_cli_sdk.dart';

import 'commands/doctor.dart';

class InquiryDoctorChecksPlugin implements CliPlugin {
  InquiryDoctorChecksPlugin({required this.checks});

  final InquiryDoctorChecks checks;

  @override
  CliPluginManifest get manifest => const CliPluginManifest(
    id: 'inquiry.doctor_checks',
    displayName: 'Inquiry prerequisite checks',
    version: '1.0.0',
    hostApiVersion: '^$cliPluginHostApiVersion',
    // `DoctorPlugin` must run first: it is the one that calls
    // `host.declareExtensionPoint<CliDoctorCheck>('doctor.checks')`, and
    // `contribute` throws `PLUGIN_EXTENSION_POINT_UNDECLARED` otherwise.
    requires: ['modular_cli.doctor'],
  );

  @override
  void setup(CliPluginHost host) {
    void add(String name, Future<CliCheckResult> Function() run) {
      host.contribute<CliDoctorCheck>(
        DoctorPlugin.extensionPoint,
        CliDoctorCheck(name: name, run: run),
      );
    }

    add('inquiry', checks.checkInquiryVersion);
    add('git', checks.checkGit);
    add('gh', checks.checkGh);
    add('gh auth', checks.checkGhAuth);
    add('inquiry init', checks.checkInit);
    add('assets', checks.checkAssets);
    // No 'update' check here: `modular_cli_sdk`'s `InstallationPlugin`
    // (see `inquiry_cli.dart`) contributes its own `release` doctor check,
    // which covers the same ground without swallowing a failed lookup the
    // way this CLI's own version_check.dart-backed check used to.
    for (final adapter in checks.activeAdapters) {
      add('host: ${adapter.name}', () => checks.checkHost(adapter));
    }
    add('host deployment', checks.checkAnyHostActive);
    add('opencode/ollama context', checks.checkOllamaContext);
  }
}
