import 'dart:io';

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

  // `runUninstallCleanup` runs from `ModularCli.use()`'s uninstall middleware,
  // ahead of `InstallationPlugin`'s own `uninstall` route (which owns the
  // Windows-safe wait-then-delete fix, ccisnedev/inquiry#321). This covers
  // only the Inquiry-specific side effects it is responsible for.
  group('runUninstallCleanup', () {
    test('cleans deployed hosts', () {
      final ours = Directory(
        p.join(homeDir.path, '.fake', 'skills', 'iq-analyze'),
      )..createSync(recursive: true);
      final theirs = Directory(
        p.join(homeDir.path, '.fake', 'skills', 'legion'),
      )..createSync(recursive: true);

      runUninstallCleanup(
        deployer: deployer,
        installDir: tempDir.path,
        platformOps: FakePlatformOps(),
        workingDirectory: tempDir.path,
      );

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

    test('does not fail when nothing was deployed', () {
      expect(
        () => runUninstallCleanup(
          deployer: deployer,
          installDir: tempDir.path,
          platformOps: FakePlatformOps(),
          workingDirectory: tempDir.path,
        ),
        returnsNormally,
      );
    });

    test('removes bin dir from PATH via platformOps', () {
      final binDir = p.join(tempDir.path, 'bin');
      final sep = Platform.isWindows ? ';' : ':';
      final otherA = Platform.isWindows ? r'C:\other' : '/other';
      final otherB = Platform.isWindows ? r'C:\more' : '/more';
      final fakePath = '$otherA$sep$binDir$sep$otherB';
      final ops = FakePlatformOps(fakeEnvValue: fakePath);

      runUninstallCleanup(
        deployer: deployer,
        installDir: tempDir.path,
        platformOps: ops,
        workingDirectory: tempDir.path,
      );

      expect(ops.calls, contains('getEnvVariable(PATH)'));
      final expectedNew = '$otherA$sep$otherB';
      expect(ops.calls, contains('setEnvVariable(PATH, $expectedNew)'));
    });

    test('does not call setEnvVariable when bin dir is not in PATH', () {
      final sep = Platform.isWindows ? ';' : ':';
      final otherA = Platform.isWindows ? r'C:\other' : '/other';
      final otherB = Platform.isWindows ? r'C:\more' : '/more';
      final ops = FakePlatformOps(fakeEnvValue: '$otherA$sep$otherB');

      runUninstallCleanup(
        deployer: deployer,
        installDir: tempDir.path,
        platformOps: ops,
        workingDirectory: tempDir.path,
      );

      expect(ops.calls, contains('getEnvVariable(PATH)'));
      expect(ops.calls.where((c) => c.startsWith('setEnvVariable')), isEmpty);
    });

    test('removes .github/agents/inquiry.agent.md from working directory', () {
      final agentFile = File(
        p.join(tempDir.path, '.github', 'agents', 'inquiry.agent.md'),
      );
      agentFile.parent.createSync(recursive: true);
      agentFile.writeAsStringSync('# APE Agent');

      runUninstallCleanup(
        deployer: deployer,
        installDir: tempDir.path,
        platformOps: FakePlatformOps(),
        workingDirectory: tempDir.path,
      );

      expect(
        agentFile.existsSync(),
        isFalse,
        reason: 'iq uninstall must remove repo-scoped agent',
      );
    });

    test('does not fail if .github/agents/inquiry.agent.md does not exist', () {
      expect(
        () => runUninstallCleanup(
          deployer: deployer,
          installDir: tempDir.path,
          platformOps: FakePlatformOps(),
          workingDirectory: tempDir.path,
        ),
        returnsNormally,
      );
    });

    // `InstallationPlugin`'s own `uninstall` route only removes an alias that
    // `sameFile()`s the executable (a symlink or hard link to it) — by design,
    // it leaves alone an alias that resolves elsewhere rather than guessing.
    // On Windows, `iq.cmd` is a batch shim that calls `%~dp0inquiry.exe`: a
    // distinct file, not a link, so the plugin never removes it and it would
    // otherwise survive `iq uninstall` (the exact "leaves files behind" bug
    // in ccisnedev/inquiry#321).
    test(
      'removes the iq.cmd alias shim, which InstallationPlugin leaves behind',
      () {
        final binDir = Directory(p.join(tempDir.path, 'bin'))
          ..createSync(recursive: true);
        final shim = File(p.join(binDir.path, 'iq.cmd'));
        shim.writeAsStringSync('@"%~dp0inquiry.exe" %*');

        runUninstallCleanup(
          deployer: deployer,
          installDir: tempDir.path,
          platformOps: FakePlatformOps(),
          workingDirectory: tempDir.path,
        );

        expect(shim.existsSync(), isFalse);
      },
    );

    test('does not fail if the iq.cmd alias shim does not exist', () {
      expect(
        () => runUninstallCleanup(
          deployer: deployer,
          installDir: tempDir.path,
          platformOps: FakePlatformOps(),
          workingDirectory: tempDir.path,
        ),
        returnsNormally,
      );
    });
  });
}
