import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:inquiry_cli/modules/global/commands/upgrade.dart';

import 'platform_ops_test.dart' show FakePlatformOps;

/// Captures every line written to it, the way `_NullSink` used to discard
/// them — except this keeps them, since these tests assert on the transcript.
class _CapturingSink implements IOSink {
  final List<String> lines = [];

  @override
  void writeln([Object? object = '']) => lines.add('$object');

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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

  // `redeployHostsAfterUpgrade` is what `ModularCli.use()`'s upgrade
  // middleware calls once `InstallationPlugin`'s own `upgrade` route has
  // replaced the binary. It is best effort by design (#300): a failed or
  // stalled redeploy must not read as a failed upgrade, since the upgrade has
  // already succeeded by the time this runs.
  group('redeployHostsAfterUpgrade', () {
    test('echoes what the child actually deployed', () async {
      final ops = FakePlatformOps()
        ..postInstallResult = ProcessResult(
          0,
          0,
          'deployed to host claude',
          '',
        );
      final progress = _CapturingSink();

      await redeployHostsAfterUpgrade(
        installDir: '/fake/dir',
        platformOps: ops,
        progress: progress,
      );

      expect(ops.calls, contains('runPostInstall(/fake/dir)'));
      expect(progress.lines, contains('  deployed to host claude'));
    });

    test('reports a non-zero exit rather than throwing', () async {
      final ops = FakePlatformOps()
        ..postInstallResult = ProcessResult(0, 1, '', 'no host');
      final progress = _CapturingSink();

      await expectLater(
        redeployHostsAfterUpgrade(
          installDir: '/fake/dir',
          platformOps: ops,
          progress: progress,
        ),
        completes,
      );

      expect(progress.lines.any((l) => l.contains('failed (exit 1)')), isTrue);
      expect(progress.lines.any((l) => l.contains('iq host get')), isTrue);
    });

    test('reports a thrown error rather than propagating it', () async {
      final progress = _CapturingSink();

      await expectLater(
        redeployHostsAfterUpgrade(
          installDir: '/fake/dir',
          platformOps: _ThrowingPlatformOps(),
          progress: progress,
        ),
        completes,
      );

      expect(progress.lines.any((l) => l.contains('stopped:')), isTrue);
    });
  });

  // `InstallationPlugin` deliberately downloads a bare per-platform
  // executable, never an archive (see its own doc comment on why). Inquiry
  // still ships `assets/` alongside the binary, versioned in lockstep with
  // it, so without `refreshAssetsAfterUpgrade` those files would silently go
  // stale the first time `iq upgrade --apply` runs under the new plugin
  // (ccisnedev/inquiry#321). Best effort, like `redeployHostsAfterUpgrade`:
  // the binary is already replaced and the upgrade already succeeded by the
  // time this runs.
  group('refreshAssetsAfterUpgrade', () {
    late Directory installDir;

    setUp(() {
      installDir = Directory.systemTemp.createTempSync('inquiry_refresh_test_');
    });

    tearDown(() {
      if (installDir.existsSync()) installDir.deleteSync(recursive: true);
    });

    String releaseJsonWith(String assetName) => jsonEncode({
      'tag_name': 'v9.9.9',
      'assets': [
        {
          'name': assetName,
          'browser_download_url': 'https://example.test/$assetName',
        },
      ],
    });

    test(
      'downloads the latest release archive and replaces the assets folder',
      () async {
        // Already on disk, to prove the folder is replaced, not merged into.
        final oldAssets = Directory(p.join(installDir.path, 'assets'))
          ..createSync();
        File(p.join(oldAssets.path, 'stale.txt')).writeAsStringSync('old');

        final ops = FakePlatformOps()
          ..onExpandArchive = (archivePath, destDir) {
            final newAssets = Directory(p.join(destDir, 'assets'))
              ..createSync(recursive: true);
            File(p.join(newAssets.path, 'fresh.txt')).writeAsStringSync('new');
          };
        final progress = _CapturingSink();
        String? capturedReleaseUrl;
        String? capturedDownloadUrl;

        await refreshAssetsAfterUpgrade(
          installDir: installDir.path,
          operatingSystem: 'linux',
          platformOps: ops,
          fetchText: (url) async {
            capturedReleaseUrl = url;
            return releaseJsonWith('inquiry-linux-x64.tar.gz');
          },
          downloadBytes: (url) async {
            capturedDownloadUrl = url;
            return <int>[1, 2, 3];
          },
          progress: progress,
        );

        expect(
          capturedReleaseUrl,
          contains('api.github.com/repos/ccisnedev/inquiry/releases/latest'),
        );
        expect(
          capturedDownloadUrl,
          'https://example.test/inquiry-linux-x64.tar.gz',
        );
        expect(ops.calls.any((c) => c.startsWith('expandArchive(')), isTrue);
        expect(
          File(p.join(installDir.path, 'assets', 'fresh.txt')).existsSync(),
          isTrue,
        );
        expect(
          File(p.join(installDir.path, 'assets', 'stale.txt')).existsSync(),
          isFalse,
        );
        expect(progress.lines.any((l) => l.contains('done')), isTrue);
      },
    );

    test('skips without touching disk when the platform has no configured '
        'archive asset', () async {
      final ops = FakePlatformOps();
      final progress = _CapturingSink();

      await refreshAssetsAfterUpgrade(
        installDir: installDir.path,
        operatingSystem: 'macos',
        platformOps: ops,
        progress: progress,
      );

      expect(ops.calls, isEmpty);
      expect(progress.lines.any((l) => l.contains('skipped')), isTrue);
    });

    test('skips when the release has no matching asset', () async {
      final ops = FakePlatformOps();
      final progress = _CapturingSink();

      await refreshAssetsAfterUpgrade(
        installDir: installDir.path,
        operatingSystem: 'linux',
        platformOps: ops,
        fetchText: (url) async => releaseJsonWith('some-other-asset.zip'),
        progress: progress,
      );

      expect(ops.calls, isEmpty);
      expect(progress.lines.any((l) => l.contains('skipped')), isTrue);
    });

    test(
      'leaves the existing assets folder alone when the archive has none',
      () async {
        final oldAssets = Directory(p.join(installDir.path, 'assets'))
          ..createSync();
        File(p.join(oldAssets.path, 'kept.txt')).writeAsStringSync('kept');

        final ops = FakePlatformOps(); // onExpandArchive is a no-op by default
        final progress = _CapturingSink();

        await refreshAssetsAfterUpgrade(
          installDir: installDir.path,
          operatingSystem: 'linux',
          platformOps: ops,
          fetchText: (url) async => releaseJsonWith('inquiry-linux-x64.tar.gz'),
          downloadBytes: (url) async => <int>[1, 2, 3],
          progress: progress,
        );

        expect(
          File(p.join(installDir.path, 'assets', 'kept.txt')).existsSync(),
          isTrue,
        );
        expect(progress.lines.any((l) => l.contains('skipped')), isTrue);
      },
    );

    test('reports a thrown error rather than propagating it', () async {
      final progress = _CapturingSink();

      await expectLater(
        refreshAssetsAfterUpgrade(
          installDir: installDir.path,
          operatingSystem: 'linux',
          fetchText: (url) async => throw StateError('network down'),
          progress: progress,
        ),
        completes,
      );

      expect(progress.lines.any((l) => l.contains('stopped:')), isTrue);
    });
  });
}

class _ThrowingPlatformOps extends FakePlatformOps {
  @override
  Future<ProcessResult> runPostInstall(String installDir) {
    throw StateError('boom');
  }
}
