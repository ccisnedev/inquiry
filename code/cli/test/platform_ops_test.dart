import 'dart:io';

import 'package:test/test.dart';

import 'package:inquiry_cli/hosts/platform_ops.dart';

/// A fake [PlatformOps] for testing. Records calls and returns
/// configurable values without touching the real OS.
///
/// Binary replacement and uninstall-directory deletion moved to
/// `modular_cli_sdk`'s `InstallationPlugin` (ccisnedev/inquiry#321): this
/// fake only covers what [PlatformOps] still owns.
class FakePlatformOps implements PlatformOps {
  final String? fakeEnvValue;

  final List<String> calls = [];

  FakePlatformOps({this.fakeEnvValue});

  @override
  String? getEnvVariable(String name) {
    calls.add('getEnvVariable($name)');
    return fakeEnvValue;
  }

  @override
  Future<void> setEnvVariable(String name, String value) async {
    calls.add('setEnvVariable($name, $value)');
  }

  /// What the fake child reports back. `upgrade` echoes this, so a test can
  /// assert the user is shown which hosts were deployed to.
  ProcessResult postInstallResult = ProcessResult(
    0,
    0,
    'Inquiry agent + skills deployed to host claude',
    '',
  );

  @override
  Future<ProcessResult> runPostInstall(String installDir) async {
    calls.add('runPostInstall($installDir)');
    return postInstallResult;
  }

  /// What [expandArchive] does to [destDir] once "extraction" is recorded.
  /// Defaults to doing nothing, matching an archive with no `assets/` folder
  /// in it — a test that needs one configures this.
  void Function(String archivePath, String destDir) onExpandArchive = (_, _) {};

  @override
  Future<void> expandArchive(String archivePath, String destDir) async {
    calls.add('expandArchive($archivePath, $destDir)');
    onExpandArchive(archivePath, destDir);
  }
}

void main() {
  group('PlatformOps contract', () {
    late FakePlatformOps fake;

    setUp(() {
      fake = FakePlatformOps();
    });

    test('FakePlatformOps implements all methods', () {
      // If this compiles, the fake satisfies the interface.
      final PlatformOps ops = fake;
      expect(ops, isA<PlatformOps>());
    });

    test('getEnvVariable returns configured value', () {
      final ops = FakePlatformOps(fakeEnvValue: 'C:\\Users\\bin');
      final result = ops.getEnvVariable('PATH');
      expect(result, equals('C:\\Users\\bin'));
      expect(ops.calls, contains('getEnvVariable(PATH)'));
    });

    test('getEnvVariable returns null when not configured', () {
      expect(fake.getEnvVariable('NONEXISTENT'), isNull);
    });

    test('setEnvVariable completes without error', () async {
      await fake.setEnvVariable('PATH', '/usr/local/bin');
      expect(fake.calls, contains('setEnvVariable(PATH, /usr/local/bin)'));
    });

    test('runPostInstall completes and returns the child result', () async {
      final result = await fake.runPostInstall('/opt/ape');
      expect(fake.calls, contains('runPostInstall(/opt/ape)'));
      // The caller needs the result to report what was deployed (#300).
      expect(result.exitCode, 0);
      expect(result.stdout, contains('deployed'));
    });

    // `expandArchive` exists only to refresh the bundled `assets/` folder
    // after `upgrade`: `InstallationPlugin`'s own binary replacement
    // downloads a bare executable, never an archive (ccisnedev/inquiry#321).
    test('expandArchive records what it was asked to extract', () async {
      await fake.expandArchive('/tmp/release.zip', '/opt/ape/extracted');
      expect(
        fake.calls,
        contains('expandArchive(/tmp/release.zip, /opt/ape/extracted)'),
      );
    });
  });

  group('PlatformOps.current()', () {
    test('returns a non-null PlatformOps instance', () {
      final ops = PlatformOps.current();
      expect(ops, isA<PlatformOps>());
    });
  });

  // `iq host get` is a command now, so it refuses to act unless told which of
  // --plan and --apply was meant. The post-install child has no terminal to be
  // asked on, and the upgrade it belongs to was already approved — so it
  // carries the approval rather than asking for a second one. Drop either flag
  // and every upgrade reports a failed redeploy.
  group('post-install arguments', () {
    test('carry the approval the upgrade already took', () {
      expect(postInstallArguments, ['host', 'get', '--apply', '--autoapprove']);
    });
  });
}
