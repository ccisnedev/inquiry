import 'dart:io';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:inquiry_cli/assets.dart';
import 'package:inquiry_cli/modules/global/commands/uninstall.dart';
import 'package:inquiry_cli/hosts/deployer.dart';
import 'package:inquiry_cli/hosts/host_adapter.dart';

class _FakeAdapter extends HostAdapter {
  @override
  String get name => 'fake';

  @override
  String baseDirectory(String homeDir) => p.join(homeDir, '.fake');

  @override
  String skillsDirectory(String homeDir) => p.join(homeDir, '.fake', 'skills');

  @override
  String agentDirectory(String homeDir) => p.join(homeDir, '.fake', 'agents');
}

void main() {
  late Directory tempDir;
  late Directory homeDir;
  late HostDeployer deployer;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('iq_uninstall_test_');
    homeDir = Directory(p.join(tempDir.path, 'home'))..createSync();

    final skillDir = Directory(
      p.join(tempDir.path, 'assets', 'skills', 'doc-read'),
    );
    skillDir.createSync(recursive: true);
    File(p.join(skillDir.path, 'SKILL.md')).writeAsStringSync('# Doc Read');

    final agentDir = Directory(p.join(tempDir.path, 'assets', 'agents'));
    agentDir.createSync(recursive: true);
    File(
      p.join(agentDir.path, 'inquiry.agent.md'),
    ).writeAsStringSync('# APE Agent');

    deployer = HostDeployer(
      assets: Assets(root: tempDir.path),
      adapters: [_FakeAdapter()],
      homeDir: homeDir.path,
    );
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  // `CleanDeployedHosts` and `RemoveRepoScopedAgent` are inquiry's own extra
  // steps for `iq uninstall`, supplied to the SDK's `InstallationPlugin`
  // through `CliInstallationConfig.preUninstallSteps` (see
  // `lib/modules/global/installation_config.dart`). Taking `bin/` off PATH
  // and scheduling the install directory for deletion are the plugin's own
  // `UnsetFromPath` / `DeleteInstallation` now, covered by `modular_cli_sdk`'s
  // own test suite, not repeated here.
  group('CleanDeployedHosts', () {
    test('previews naming every host this machine deployed to', () {
      final preview = CleanDeployedHosts(deployer).preview();

      expect(preview.verb, 'clean');
      expect(preview.target, contains('every host'));
    });

    test('cleans deployed hosts', () async {
      final ours = Directory(
        p.join(homeDir.path, '.fake', 'skills', 'iq-analyze'),
      )..createSync(recursive: true);
      final theirs = Directory(
        p.join(homeDir.path, '.fake', 'skills', 'legion'),
      )..createSync(recursive: true);

      await CleanDeployedHosts(deployer).perform(StepContext(const {}));

      // Uninstalling Inquiry removes Inquiry. It does not empty a host's
      // skills directory, which holds other tools' work and the user's:
      // uninstalling one program has never been a licence to delete another's
      // files. `clean` takes the `iq-` namespace and the agent file, and the
      // directories themselves stay.
      expect(
        Directory(p.join(homeDir.path, '.fake', 'skills')).existsSync(),
        isTrue,
      );
      expect(ours.existsSync(), isFalse);
      expect(
        theirs.existsSync(),
        isTrue,
        reason: "an unprefixed skill is not provably Inquiry's to remove",
      );
    });

    test('touches nothing under preview: the deployed host survives', () {
      final ours = Directory(
        p.join(homeDir.path, '.fake', 'skills', 'iq-analyze'),
      )..createSync(recursive: true);

      CleanDeployedHosts(deployer).preview();

      expect(
        ours.existsSync(),
        isTrue,
        reason: 'a preview changes nothing, including the sweep',
      );
    });
  });

  group('RemoveRepoScopedAgent', () {
    test('previews as present when the file is there', () {
      final agentFile = File(
        p.join(tempDir.path, '.github', 'agents', 'inquiry.agent.md'),
      );
      agentFile.parent.createSync(recursive: true);
      agentFile.writeAsStringSync('# APE Agent');

      final preview = RemoveRepoScopedAgent(agentFile.path).preview();

      expect(preview.verb, 'remove');
    });

    test('previews as absent when the file is not there', () {
      final path = p.join(
        tempDir.path,
        '.github',
        'agents',
        'inquiry.agent.md',
      );

      final preview = RemoveRepoScopedAgent(path).preview();

      expect(preview.verb, 'absent');
    });

    test('removes .github/agents/inquiry.agent.md when it exists', () async {
      final agentFile = File(
        p.join(tempDir.path, '.github', 'agents', 'inquiry.agent.md'),
      );
      agentFile.parent.createSync(recursive: true);
      agentFile.writeAsStringSync('# APE Agent');

      final outcome = await RemoveRepoScopedAgent(
        agentFile.path,
      ).perform(StepContext(const {}));

      expect(outcome.verb, 'remove');
      expect(
        agentFile.existsSync(),
        isFalse,
        reason: 'iq uninstall must remove repo-scoped agent',
      );
    });

    test('does not fail when the file does not exist', () async {
      final path = p.join(
        tempDir.path,
        '.github',
        'agents',
        'inquiry.agent.md',
      );

      final outcome = await RemoveRepoScopedAgent(
        path,
      ).perform(StepContext(const {}));

      expect(outcome.verb, 'absent');
    });
  });
}
