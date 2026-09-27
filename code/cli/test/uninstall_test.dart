import 'dart:io';

// `UninstallInput`/`UninstallOutput`/`UninstallCommand` are hidden:
// `modular_cli_sdk` re-exports its own `InstallationPlugin`'s classes of the
// same names, which this test does not exercise (see
// `commands/uninstall.dart` for Inquiry's own, unrelated implementation).
import 'package:modular_cli_sdk/modular_cli_sdk.dart'
    hide UninstallInput, UninstallOutput, UninstallCommand;
import 'package:modular_cli_sdk/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:inquiry_cli/assets.dart';
import 'package:inquiry_cli/modules/global/commands/uninstall.dart';
import 'package:inquiry_cli/hosts/deployer.dart';
import 'package:inquiry_cli/hosts/host_adapter.dart';

import 'platform_ops_test.dart' show FakePlatformOps;

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
    tempDir = Directory.systemTemp.createTempSync('ape_uninstall_test_');
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

  group('UninstallCommand', () {
    test('cleans deployed hosts', () async {
      final ours = Directory(
        p.join(homeDir.path, '.fake', 'skills', 'iq-analyze'),
      )..createSync(recursive: true);
      final theirs = Directory(
        p.join(homeDir.path, '.fake', 'skills', 'legion'),
      )..createSync(recursive: true);

      final command = UninstallCommand(
        UninstallInput(installDir: tempDir.path),
        deployer: deployer,
        platformOps: FakePlatformOps(),
      );

      final output = await applyCommand(command);

      expect(output.exitCode, ExitCode.ok);
      expect(output.toText(), contains('uninstalled'));

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

    test('exits 0 when nothing was deployed', () async {
      final command = UninstallCommand(
        UninstallInput(installDir: tempDir.path),
        deployer: deployer,
        platformOps: FakePlatformOps(),
      );

      final output = await applyCommand(command);
      expect(output.exitCode, ExitCode.ok);
    });

    test('removes bin dir from PATH via platformOps', () async {
      final binDir = p.join(tempDir.path, 'bin');
      final sep = Platform.isWindows ? ';' : ':';
      final otherA = Platform.isWindows ? r'C:\other' : '/other';
      final otherB = Platform.isWindows ? r'C:\more' : '/more';
      final fakePath = '$otherA$sep$binDir$sep$otherB';
      final ops = FakePlatformOps(fakeEnvValue: fakePath);

      final command = UninstallCommand(
        UninstallInput(installDir: tempDir.path),
        deployer: deployer,
        platformOps: ops,
      );

      await applyCommand(command);

      expect(ops.calls, contains('getEnvVariable(PATH)'));
      final expectedNew = '$otherA$sep$otherB';
      expect(
        ops.calls,
        contains('setEnvVariable(PATH, $expectedNew)'),
      );
    });

    test('does not call setEnvVariable when bin dir is not in PATH', () async {
      final sep = Platform.isWindows ? ';' : ':';
      final otherA = Platform.isWindows ? r'C:\other' : '/other';
      final otherB = Platform.isWindows ? r'C:\more' : '/more';
      final ops = FakePlatformOps(fakeEnvValue: '$otherA$sep$otherB');

      final command = UninstallCommand(
        UninstallInput(installDir: tempDir.path),
        deployer: deployer,
        platformOps: ops,
      );

      await applyCommand(command);

      expect(ops.calls, contains('getEnvVariable(PATH)'));
      expect(
        ops.calls.where((c) => c.startsWith('setEnvVariable')),
        isEmpty,
      );
    });

    test('schedules deletion of install directory', () async {
      final ops = FakePlatformOps();

      final command = UninstallCommand(
        UninstallInput(installDir: tempDir.path),
        deployer: deployer,
        platformOps: ops,
      );

      await applyCommand(command);

      expect(ops.calls, contains('scheduleDeletion(${tempDir.path})'));
    });

    test('removes .github/agents/inquiry.agent.md from working directory',
        () async {
      final agentFile = File(
        p.join(tempDir.path, '.github', 'agents', 'inquiry.agent.md'),
      );
      agentFile.parent.createSync(recursive: true);
      agentFile.writeAsStringSync('# APE Agent');

      final command = UninstallCommand(
        UninstallInput(installDir: tempDir.path),
        deployer: deployer,
        workingDirectory: tempDir.path,
        platformOps: FakePlatformOps(),
      );

      await applyCommand(command);

      expect(agentFile.existsSync(), isFalse,
          reason: 'iq uninstall must remove repo-scoped agent');
    });

    test('does not fail if .github/agents/inquiry.agent.md does not exist',
        () async {
      final command = UninstallCommand(
        UninstallInput(installDir: tempDir.path),
        deployer: deployer,
        workingDirectory: tempDir.path,
        platformOps: FakePlatformOps(),
      );

      await expectLater(applyCommand(command), completes);
    });
  });

  // What `--plan` shows. These are the assertions the old `execute()` could not
  // make: that the order is a fact about the command rather than a comment, and
  // that planning an uninstall uninstalls nothing.
  group('UninstallCommand under --plan', () {
    test('names the four steps, hosts first and the directory last', () async {
      final previews = await previewCommand(
        UninstallCommand(
          UninstallInput(installDir: tempDir.path),
          deployer: deployer,
          workingDirectory: tempDir.path,
          platformOps: FakePlatformOps(),
        ),
      );

      expect(
        previews.map((p) => p.verb).toList(),
        ['clean', 'absent', 'unset', 'delete'],
      );
    });

    // PATH comes off before the directory is scheduled for deletion, so there
    // is never a window in which the entry points at a directory on its way
    // out.
    test('unsets PATH before it deletes the installation', () async {
      final previews = await previewCommand(
        UninstallCommand(
          UninstallInput(installDir: tempDir.path),
          deployer: deployer,
          workingDirectory: tempDir.path,
          platformOps: FakePlatformOps(),
        ),
      );

      expect(
        previews.indexWhere((p) => p.verb == 'unset'),
        lessThan(previews.indexWhere((p) => p.verb == 'delete')),
      );
    });

    test('says the installation directory it would delete', () async {
      final previews = await previewCommand(
        UninstallCommand(
          UninstallInput(installDir: tempDir.path),
          deployer: deployer,
          workingDirectory: tempDir.path,
          platformOps: FakePlatformOps(),
        ),
      );

      final delete = previews.firstWhere((p) => p.verb == 'delete');
      expect(delete.target, tempDir.path);
      expect(delete.detail, contains('not touched'));
    });

    test('touches nothing: the deployed host survives the plan', () async {
      final ours = Directory(
        p.join(homeDir.path, '.fake', 'skills', 'iq-analyze'),
      )..createSync(recursive: true);
      final ops = FakePlatformOps();

      await previewCommand(
        UninstallCommand(
          UninstallInput(installDir: tempDir.path),
          deployer: deployer,
          workingDirectory: tempDir.path,
          platformOps: ops,
        ),
      );

      expect(
        ours.existsSync(),
        isTrue,
        reason: 'a plan changes nothing, including the sweep',
      );
      expect(ops.calls, isEmpty);
    });

    test('reports the repo-scoped agent as present when it is there', () async {
      final agentFile = File(
        p.join(tempDir.path, '.github', 'agents', 'inquiry.agent.md'),
      );
      agentFile.parent.createSync(recursive: true);
      agentFile.writeAsStringSync('# APE Agent');

      final previews = await previewCommand(
        UninstallCommand(
          UninstallInput(installDir: tempDir.path),
          deployer: deployer,
          workingDirectory: tempDir.path,
          platformOps: FakePlatformOps(),
        ),
      );

      expect(previews.map((p) => p.verb).toList(),
          ['clean', 'remove', 'unset', 'delete']);
      expect(agentFile.existsSync(), isTrue);
    });
  });
}
