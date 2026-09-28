/// Inquiry's own extra step for `iq upgrade`, supplied to the SDK's
/// `InstallationPlugin` via `CliInstallationConfig.postUpgradeSteps`.
///
/// Fetching the release, downloading it, and extracting it over the
/// installation are all handled by the plugin's own `UpgradeCommand` now
/// (`package:modular_cli_sdk`). What is left here is what inquiry adds on
/// top of that: redeploying every host with the freshly upgraded binary.
library;

import 'dart:io';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';

/// Redeploys the agent and skills into every host, using the new binary.
///
/// **Best effort, and that is deliberate (#300).** By the time this runs the
/// binary and its assets are in place, so the upgrade has already succeeded.
/// Redeploying reaches into third-party tools' directories and can fail or
/// stall for reasons that have nothing to do with the upgrade — so this reports
/// and never throws. A failure here must not take the upgrade down with it.
///
/// This is why `CliInstallationConfig.verifyAfterInstall` is `false` for
/// inquiry: the plugin's own inline verification is hard-fail (it would
/// throw and abort the upgrade), and would duplicate this lenient step,
/// which is inquiry's actual post-install check.
class RedeployHosts implements Step {
  RedeployHosts({
    required this.platformOps,
    required this.installDir,
    IOSink? progress,
  }) : progress = progress ?? stderr;

  final PlatformOps platformOps;
  final String installDir;
  final IOSink progress;

  @override
  Preview preview() => Preview(
    verb: 'deploy',
    target: 'every host on this machine',
    detail: 'best effort — the upgrade stands whether or not this succeeds',
  );

  @override
  Future<Outcome> perform(StepContext context) async {
    progress.writeln('Deploying hosts...');
    try {
      final result = await platformOps.runPostInstall(
        installDir,
        timeout: postInstallTimeout,
      );
      // Echo what the child actually did. Swallowing it made a deploy to
      // nothing look identical to a deploy to everything.
      for (final line in postInstallOutputLines(result)) {
        progress.writeln('  $line');
      }
      if (result.exitCode != 0) {
        return Outcome(
          verb: 'deploy',
          target: 'every host on this machine',
          detail:
              'failed (exit ${result.exitCode}) — run '
              '`iq host get --apply` to retry, or `iq doctor` to inspect',
          values: {'deployed': false},
        );
      }
      return Outcome(
        verb: 'deploy',
        target: 'every host on this machine',
        values: {'deployed': true},
      );
    } on Object catch (error) {
      return Outcome(
        verb: 'deploy',
        target: 'every host on this machine',
        detail:
            'stopped: $error — run `iq host get --apply` to retry, or '
            '`iq doctor` to inspect',
        values: {'deployed': false},
      );
    }
  }
}

/// The child's combined output, trimmed and split — stdout first, then stderr.
///
/// `Process.run` buffers both; printing them is what lets a user see which
/// hosts were deployed to, or that none were. Blank lines are dropped so the
/// echoed block stays tight under `Deploying hosts...`.
///
/// Visible for testing.
List<String> postInstallOutputLines(ProcessResult result) =>
    ['${result.stdout}', '${result.stderr}']
        .expand((s) => s.split('\n'))
        .map((l) => l.trimRight())
        .where((l) => l.isNotEmpty)
        .toList(growable: false);
