import 'dart:io';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:inquiry_cli/assets.dart';
import 'package:inquiry_cli/hosts/deployer.dart';
import 'package:inquiry_cli/modules/global/commands/uninstall.dart';
import 'package:inquiry_cli/modules/global/commands/upgrade.dart';
import 'package:inquiry_cli/modules/global/installation_config.dart';

import 'support/fake_platform_ops.dart';

/// `inquiryInstallationConfig` is what `inquiry_cli.dart` hands to the SDK's
/// `InstallationPlugin`. It is kept in its own file precisely so these
/// wiring facts (which steps, in which order, with `verifyAfterInstall`
/// turned off) are visible to a test without going through the whole CLI or
/// a real upgrade/uninstall.
void main() {
  late Directory tempDir;
  late HostDeployer cleaner;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('iq_installation_config_');
    cleaner = HostDeployer(
      assets: Assets(root: tempDir.path),
      adapters: const [],
      homeDir: tempDir.path,
    );
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  CliInstallationConfigFixture buildFixture() {
    final agentPath = p.join(
      tempDir.path,
      '.github',
      'agents',
      'inquiry.agent.md',
    );
    final config = inquiryInstallationConfig(
      cleaner: cleaner,
      repoScopedAgentPath: agentPath,
    );
    return CliInstallationConfigFixture(config: config, agentPath: agentPath);
  }

  test('repository, executable and alias identify inquiry itself', () {
    final config = buildFixture().config;

    expect(config.repository, 'ccisnedev/inquiry');
    expect(config.executable, 'inquiry');
    expect(config.alias, 'iq');
  });

  test('assets name the release archive per platform', () {
    final config = buildFixture().config;

    expect(config.assets, {
      'windows': 'inquiry-windows-x64.zip',
      'linux': 'inquiry-linux-x64.tar.gz',
    });
  });

  // Carries the approval the upgrade already took: the redeployed child has
  // no terminal to be asked on. See `inquiryPostInstallArguments`.
  test('postInstallArguments run host get with the approval already given', () {
    final config = buildFixture().config;

    expect(config.postInstallArguments, [
      'host',
      'get',
      '--apply',
      '--autoapprove',
    ]);
  });

  // The plugin's own inline verification is hard-fail; inquiry's own
  // `RedeployHosts`, wired through `postUpgradeSteps` below, is lenient and
  // must be the only post-install check that runs.
  test('verifyAfterInstall is false, so the hard-fail check never runs', () {
    final config = buildFixture().config;

    expect(config.verifyAfterInstall, isFalse);
  });

  test('postUpgradeSteps builds exactly one RedeployHosts, from the install '
      'directory and platform ops the upgrade itself used', () {
    final config = buildFixture().config;
    final ops = FakePlatformOps();

    final steps = config.postUpgradeSteps!('/fake/dir', ops);

    expect(steps, hasLength(1));
    expect(steps.single, isA<RedeployHosts>());
    final redeploy = steps.single as RedeployHosts;
    expect(redeploy.installDir, '/fake/dir');
    expect(redeploy.platformOps, same(ops));
  });

  test(
    'preUninstallSteps builds CleanDeployedHosts then RemoveRepoScopedAgent, '
    'in that order',
    () {
      final fixture = buildFixture();
      final ops = FakePlatformOps();

      final steps = fixture.config.preUninstallSteps!('/fake/dir', ops);

      expect(steps, hasLength(2));
      expect(steps[0], isA<CleanDeployedHosts>());
      expect((steps[0] as CleanDeployedHosts).deployer, same(cleaner));
      expect(steps[1], isA<RemoveRepoScopedAgent>());
      expect((steps[1] as RemoveRepoScopedAgent).path, fixture.agentPath);
    },
  );
}

class CliInstallationConfigFixture {
  CliInstallationConfigFixture({required this.config, required this.agentPath});

  final CliInstallationConfig config;
  final String agentPath;
}
