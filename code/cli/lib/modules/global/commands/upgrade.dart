/// `inquiry upgrade` host-redeploy — runs after `modular_cli_sdk`'s own
/// `InstallationPlugin` replaces the binary.
///
/// The plugin owns the `upgrade` route itself (download, asset resolution,
/// the safe re-check-then-write of the install target — see
/// ccisnedev/inquiry#321). What it does not know about is Inquiry-specific:
/// once the new binary is in place, the hosts it deploys into should be
/// redeployed with it. [redeployHostsAfterUpgrade] does exactly that, and is
/// wired in after the plugin's own route via `ModularCli.use`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../hosts/platform_ops.dart';
import '../../../src/version.dart';

/// The archive `install.ps1` / `install.sh` download for a first install, and
/// [refreshAssetsAfterUpgrade] downloads again for the bundled `assets/`
/// folder alone. Keyed by [Platform.operatingSystem].
///
/// `InstallationPlugin`'s own `upgrade` route downloads a *different*,
/// bare-executable asset per platform (see its doc comment on why it never
/// extracts an archive) — these names are for the archive, not that one.
const defaultUpgradeArchiveAssets = {
  'windows': 'inquiry-windows-x64.zip',
  'linux': 'inquiry-linux-x64.tar.gz',
};

/// Refreshes `installDir/assets` after `InstallationPlugin`'s own `upgrade`
/// route replaces the binary.
///
/// `InstallationPlugin` deliberately writes a bare per-platform executable,
/// never an archive (ccisnedev/inquiry#321) — nothing about it touches the
/// `assets/` folder Inquiry ships alongside its binary and versions in
/// lockstep with it. Left alone, that folder would silently drift out of
/// sync with the newly installed binary the first time `iq upgrade --apply`
/// runs. This downloads the *same* archive `install.ps1` / `install.sh` use
/// for a first install, extracts it into a scratch directory, and pulls just
/// the `assets/` folder back out of it — leaving `installDir/bin` alone.
///
/// Always resolves the latest release: `InstallationPlugin`'s own `upgrade`
/// never targets anything else either.
///
/// **Best effort, and that is deliberate (#300), matching
/// [redeployHostsAfterUpgrade].** By the time this runs the binary has
/// already been replaced and the upgrade has already succeeded; a failure
/// here — a network hiccup, a missing asset, a release with no archive for
/// this platform — is reported on [progress] and never thrown.
Future<void> refreshAssetsAfterUpgrade({
  required String installDir,
  String repo = 'ccisnedev/inquiry',
  Map<String, String> archiveAssets = defaultUpgradeArchiveAssets,
  PlatformOps? platformOps,
  String? operatingSystem,
  Future<String> Function(String url)? fetchText,
  Future<List<int>> Function(String url)? downloadBytes,
  IOSink? progress,
}) async {
  final ops = platformOps ?? PlatformOps.current();
  final os = operatingSystem ?? Platform.operatingSystem;
  final out = progress ?? stderr;
  final getText = fetchText ?? _fetchTextOverHttp;
  final getBytes = downloadBytes ?? _downloadBytesOverHttp;

  out.writeln('Refreshing bundled assets...');

  final assetName = archiveAssets[os];
  if (assetName == null) {
    out.writeln('  skipped: no archive asset configured for "$os"');
    return;
  }

  final tempDir = Directory.systemTemp.createTempSync(
    'inquiry_assets_refresh_',
  );
  try {
    final release =
        jsonDecode(
              await getText(
                'https://api.github.com/repos/$repo/releases/latest',
              ),
            )
            as Map<String, dynamic>;
    final assets = (release['assets'] as List).cast<Map<String, dynamic>>();
    final match = assets.cast<Map<String, dynamic>?>().firstWhere(
      (a) => a?['name'] == assetName,
      orElse: () => null,
    );
    if (match == null) {
      out.writeln(
        '  skipped: release ${release['tag_name']} has no asset named '
        '$assetName',
      );
      return;
    }
    final downloadUrl = match['browser_download_url'] as String;

    final archiveFile = File(p.join(tempDir.path, assetName));
    archiveFile.writeAsBytesSync(await getBytes(downloadUrl));

    final extractDir = Directory(p.join(tempDir.path, 'extracted'))
      ..createSync(recursive: true);
    await ops.expandArchive(archiveFile.path, extractDir.path);

    final newAssets = Directory(p.join(extractDir.path, 'assets'));
    if (!newAssets.existsSync()) {
      out.writeln('  skipped: downloaded archive has no assets/ folder');
      return;
    }

    _replaceDirectory(
      from: newAssets,
      to: Directory(p.join(installDir, 'assets')),
    );
    out.writeln('  done');
  } on Object catch (error) {
    out.writeln(
      '  stopped: $error — the newly installed binary may use stale '
      'bundled assets; run `iq upgrade --apply` again to retry',
    );
  } finally {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  }
}

/// Replaces [to] with a copy of [from]'s contents.
///
/// A recursive copy, not a rename: [from] lives under [Directory.systemTemp]
/// and [to] under the install directory, which a rename would fail to cross
/// on a system where they are different filesystems (`EXDEV`) — exactly the
/// kind of failure [refreshAssetsAfterUpgrade] should recover from cleanly
/// rather than leave `assets/` half-written.
void _replaceDirectory({required Directory from, required Directory to}) {
  if (to.existsSync()) {
    to.deleteSync(recursive: true);
  }
  to.createSync(recursive: true);
  for (final entity in from.listSync(recursive: true)) {
    final relative = p.relative(entity.path, from: from.path);
    final destPath = p.join(to.path, relative);
    if (entity is Directory) {
      Directory(destPath).createSync(recursive: true);
    } else if (entity is File) {
      Directory(p.dirname(destPath)).createSync(recursive: true);
      entity.copySync(destPath);
    }
  }
}

Future<String> _fetchTextOverHttp(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set('User-Agent', 'inquiry-cli/$inquiryVersion');
    request.headers.set('Accept', 'application/vnd.github+json');
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('GET $url failed: HTTP ${response.statusCode}');
    }
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close();
  }
}

Future<List<int>> _downloadBytesOverHttp(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set('User-Agent', 'inquiry-cli/$inquiryVersion');
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('GET $url failed: HTTP ${response.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }
    return bytes;
  } finally {
    client.close();
  }
}

/// Redeploys the agent and skills into every host, using the newly installed
/// binary.
///
/// **Best effort, and that is deliberate (#300).** By the time this runs the
/// upgrade has already succeeded — the binary and its assets are in place.
/// Redeploying reaches into third-party tools' directories and can fail or
/// stall for reasons that have nothing to do with the upgrade, so this
/// reports on [progress] and never throws. A failure here must not take the
/// upgrade down with it.
Future<void> redeployHostsAfterUpgrade({
  required String installDir,
  PlatformOps? platformOps,
  IOSink? progress,
}) async {
  final ops = platformOps ?? PlatformOps.current();
  final out = progress ?? stderr;

  out.writeln('Deploying hosts...');
  try {
    final result = await ops.runPostInstall(installDir);
    // Echo what the child actually did. Swallowing it made a deploy to
    // nothing look identical to a deploy to everything.
    for (final line in postInstallOutputLines(result)) {
      out.writeln('  $line');
    }
    if (result.exitCode != 0) {
      out.writeln(
        '  failed (exit ${result.exitCode}) — run `iq host get --apply` to '
        'retry, or `iq doctor` to inspect',
      );
    }
  } on Object catch (error) {
    out.writeln(
      '  stopped: $error — run `iq host get --apply` to retry, or '
      '`iq doctor` to inspect',
    );
  }
}

/// The child's combined output, trimmed and split — stdout first, then
/// stderr.
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
