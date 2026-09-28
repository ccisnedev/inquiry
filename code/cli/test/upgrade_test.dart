import 'dart:io';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import 'package:inquiry_cli/modules/global/commands/upgrade.dart';

import 'support/fake_platform_ops.dart';
import 'support/string_io_sink.dart';

void main() {
  // `Deploying hosts...` used to be the last thing a user saw: the child's
  // output was captured and thrown away, so deploying to two hosts, to one, or
  // to none all looked identical (#300).
  group('post-install output is echoed', () {
    const nl = '\n';

    test('reports what the child actually deployed', () {
      final lines = postInstallOutputLines(
        ProcessResult(
          0,
          0,
          'deployed to host claude${nl}deployed to host opencode$nl',
          '',
        ),
      );

      expect(lines, ['deployed to host claude', 'deployed to host opencode']);
    });

    test('carries stderr too, so a failure explains itself', () {
      final lines = postInstallOutputLines(
        ProcessResult(0, 1, '', 'Unknown host: "vscode"'),
      );

      expect(lines, ['Unknown host: "vscode"']);
    });

    test('drops blank lines rather than echoing empty rows', () {
      final lines = postInstallOutputLines(
        ProcessResult(0, 0, '$nl${nl}first$nl$nl', nl),
      );

      expect(lines, ['first']);
    });

    test('a deploy to nothing is visible, not silent', () {
      final lines = postInstallOutputLines(
        ProcessResult(0, 0, 'No AI coding host found on this machine', ''),
      );

      expect(lines, ['No AI coding host found on this machine']);
    });
  });

  // `RedeployHosts` is inquiry's own extra step, supplied to the SDK's
  // `InstallationPlugin` through `CliInstallationConfig.postUpgradeSteps`
  // (see `lib/modules/global/installation_config.dart`). It is best effort
  // (#300): a failure here reports, and must never fail the upgrade the way
  // the plugin's own hard-fail `verifyAfterInstall` check would.
  group('RedeployHosts', () {
    test('previews as best effort', () {
      final step = RedeployHosts(
        platformOps: FakePlatformOps(),
        installDir: '/fake/dir',
      );

      final preview = step.preview();
      expect(preview.verb, 'deploy');
      expect(preview.detail, contains('best effort'));
    });

    test('calls runPostInstall with the install directory and the shared '
        'postInstallTimeout', () async {
      final ops = FakePlatformOps();

      await RedeployHosts(
        platformOps: ops,
        installDir: '/fake/dir',
      ).perform(StepContext(const {}));

      expect(
        ops.calls,
        contains('runPostInstall(/fake/dir, timeout: $postInstallTimeout)'),
      );
    });

    test('echoes what the child actually deployed', () async {
      final ops = FakePlatformOps(
        postInstallResult: ProcessResult(0, 0, 'deployed to host claude', ''),
      );
      final progress = StringIOSink();

      await RedeployHosts(
        platformOps: ops,
        installDir: '/fake/dir',
        progress: progress,
      ).perform(StepContext(const {}));

      expect(progress.toString(), contains('deployed to host claude'));
    });

    test(
      'reports a failed deploy, with a retry hint, rather than throwing',
      () async {
        final ops = FakePlatformOps(
          postInstallResult: ProcessResult(0, 1, '', 'Unknown host'),
        );

        final outcome = await RedeployHosts(
          platformOps: ops,
          installDir: '/fake/dir',
        ).perform(StepContext(const {}));

        expect(outcome.values['deployed'], isFalse);
        expect(outcome.detail, contains('iq host get --apply'));
      },
    );

    test('reports a stopped deploy, with a retry hint, when runPostInstall '
        'throws rather than lets the upgrade fail over it', () async {
      final ops = FakePlatformOps(
        runPostInstallError: Exception('deploy child did not start'),
      );

      final outcome = await RedeployHosts(
        platformOps: ops,
        installDir: '/fake/dir',
      ).perform(StepContext(const {}));

      expect(outcome.values['deployed'], isFalse);
      expect(outcome.detail, contains('deploy child did not start'));
      expect(outcome.detail, contains('iq host get --apply'));
    });

    test('reports a successful deploy', () async {
      final ops = FakePlatformOps(
        postInstallResult: ProcessResult(0, 0, 'deployed', ''),
      );

      final outcome = await RedeployHosts(
        platformOps: ops,
        installDir: '/fake/dir',
      ).perform(StepContext(const {}));

      expect(outcome.values['deployed'], isTrue);
    });
  });
}
