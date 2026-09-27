/// `inquiry upgrade` — downloads and installs the latest Inquiry release.
///
/// Fetches the latest release from GitHub, downloads the zip, extracts it over
/// the current installation, and redeploys hosts.
library;

import 'dart:convert';
import 'dart:io';

import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:path/path.dart' as p;

import '../../../hosts/platform_ops.dart';
import '../../../src/version.dart';

const String _repo = 'ccisnedev/inquiry';

// ─── Input ──────────────────────────────────────────────────────────────────

class UpgradeInput extends Input {
  final String installDir;

  UpgradeInput({required this.installDir});

  factory UpgradeInput.fromCliRequest(CliRequest req) {
    final installDir = p.dirname(p.dirname(Platform.resolvedExecutable));
    return UpgradeInput(installDir: installDir);
  }

  /// Declares an EMPTY contract: this command accepts no option of its own, so
  /// any option beyond `--plan` / `--apply` / `--autoapprove` is refused.
  /// Omitting `contract` would mean "declares nothing" — which is how
  /// `iq init --host claude` used to run, doing nothing the flag implied.
  static const CliContract contract = CliContract.none;

  @override
  Map<String, dynamic> toJson() => {'installDir': installDir};
}

// ─── Steps ──────────────────────────────────────────────────────────────────

/// Fetches [url] into the file at [destination].
///
/// A function rather than an `HttpClient`, so the step that replaces the
/// installation does not have to know how bytes arrive — and so a test can
/// stand in for the network without faking an interface it never uses.
typedef Downloader = Future<void> Function(String url, String destination);

/// Downloads over HTTP, which is how it happens outside a test.
Future<void> downloadOverHttp(String url, String destination) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set('User-Agent', 'inquiry-cli/$inquiryVersion');
    final response = await request.close();
    await response.pipe(File(destination).openWrite());
  } finally {
    client.close();
  }
}

/// Downloads a release and extracts it over the installation.
///
/// Everything this needs — which version, which asset, which URL — was settled
/// when the step was built, from **one** call to the releases API. Asking again
/// at perform time could answer differently: a release published in between
/// would be downloaded without ever having been approved.
///
/// **It says what it is doing while it does it.** The plan states what *will*
/// happen; this states that it *is* happening, which is a different thing and
/// the only one that helps during a download of several megabytes. It goes to
/// [progress] — stderr by default — so `--json` stays machine-readable.
class ReplaceInstallation implements Step {
  ReplaceInstallation({
    required this.platformOps,
    required this.installDir,
    required this.from,
    required this.to,
    required this.asset,
    required this.downloadUrl,
    Downloader? download,
    IOSink? progress,
    String? runningExecutable,
  }) : download = download ?? downloadOverHttp,
       progress = progress ?? stderr,
       runningExecutable = runningExecutable ?? Platform.resolvedExecutable;

  final PlatformOps platformOps;
  final Downloader download;
  final String installDir;
  final String from;
  final String to;
  final String asset;
  final String downloadUrl;
  final IOSink progress;

  /// The binary this step is replacing, which on Windows has to be moved aside
  /// before it can be overwritten.
  ///
  /// **Injected, and that is not optional.** `Platform.resolvedExecutable` is
  /// the Inquiry binary only when a compiled binary is what runs. Under
  /// `dart test` and `dart run` it is the Dart VM — so a test that reached the
  /// default would rename the Dart SDK's own `dart.exe` and take the toolchain
  /// down with it.
  final String runningExecutable;

  @override
  Preview preview() => Preview(
    verb: 'replace',
    target: installDir,
    detail: ['$from → $to', 'asset $asset', 'from $downloadUrl'].join('; '),
  );

  @override
  Future<Outcome> perform(StepContext context) async {
    final tempDir = Directory.systemTemp.createTempSync('inquiry_upgrade_');
    try {
      progress.writeln('Downloading $asset ($from → $to)...');
      final zipFile = File(p.join(tempDir.path, asset));
      await download(downloadUrl, zipFile.path);

      if (Platform.isWindows) {
        // Windows locks running executables, so the outgoing binary is moved
        // aside before extraction and cleaned up afterwards — or on the next
        // upgrade, if the file is still locked.
        final bak = File('$runningExecutable.bak');
        if (bak.existsSync()) bak.deleteSync();
        File(runningExecutable).renameSync(bak.path);
      }

      progress.writeln('Extracting into $installDir...');
      await platformOps.expandArchive(zipFile.path, installDir);

      if (Platform.isWindows) {
        try {
          final bak = File('$runningExecutable.bak');
          if (bak.existsSync()) bak.deleteSync();
        } on FileSystemException {
          // Still locked — cleaned up on the next upgrade.
        }
      }
    } finally {
      tempDir.deleteSync(recursive: true);
    }

    return Outcome(
      verb: 'replace',
      target: installDir,
      values: {'from': from, 'to': to},
    );
  }
}

/// Redeploys the agent and skills into every host, using the new binary.
///
/// **Best effort, and that is deliberate (#300).** By the time this runs the
/// binary and its assets are in place, so the upgrade has already succeeded.
/// Redeploying reaches into third-party tools' directories and can fail or
/// stall for reasons that have nothing to do with the upgrade — so this reports
/// and never throws. A failure here must not take the upgrade down with it.
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
      final result = await platformOps.runPostInstall(installDir);
      // Echo what the child actually did. Swallowing it made a deploy to
      // nothing look identical to a deploy to everything.
      for (final line in postInstallOutputLines(result)) {
        progress.writeln('  $line');
      }
      if (result.exitCode != 0) {
        return Outcome(
          verb: 'deploy',
          target: 'every host on this machine',
          detail: 'failed (exit ${result.exitCode}) — run '
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
        detail: 'stopped: $error — run `iq host get --apply` to retry, or '
            '`iq doctor` to inspect',
        values: {'deployed': false},
      );
    }
  }
}

// ─── Output ─────────────────────────────────────────────────────────────────

class UpgradeOutput extends Output {
  UpgradeOutput({
    required this.previousVersion,
    required this.newVersion,
    required this.upgraded,
    this.deployed = true,
    this.reason,
  });

  final String previousVersion;
  final String newVersion;
  final bool upgraded;

  /// Whether the hosts were redeployed. False does not mean the upgrade failed.
  final bool deployed;

  /// Why nothing happened, when nothing did.
  final String? reason;

  @override
  Map<String, dynamic> toJson() => {
    'previousVersion': previousVersion,
    'newVersion': newVersion,
    'upgraded': upgraded,
    'deployed': deployed,
    if (reason != null) 'reason': reason,
  };

  @override
  int get exitCode => ExitCode.ok;

  @override
  String? toText() => upgraded
      ? [
          '✓ Upgraded: $previousVersion → $newVersion',
          if (!deployed)
            '  The CLI is upgraded. Run `iq host get --apply` to deploy '
                'the hosts.',
        ].join('\n')
      : (reason ?? 'Already on the latest version');
}

// ─── Command ────────────────────────────────────────────────────────────────

class UpgradeCommand
    implements Command<UpgradeInput, UpgradeOutput>, ExplainsNothingToDo {
  @override
  final UpgradeInput input;
  final PlatformOps platformOps;

  /// Answers the releases API. Overridden by the tests that exercise what the
  /// lookup returns.
  final HttpClient? httpClientOverride;

  /// How the release archive is fetched. A seam for the tests, and the reason
  /// the step itself knows nothing about HTTP.
  final Downloader? download;

  /// Where the steps' running commentary goes. A seam for the tests.
  final IOSink? progress;

  /// The binary being replaced. A seam for the tests, and never optional —
  /// see [ReplaceInstallation.runningExecutable].
  final String? runningExecutable;

  UpgradeCommand(
    this.input, {
    PlatformOps? platformOps,
    this.httpClientOverride,
    this.download,
    this.progress,
    this.runningExecutable,
  }) : platformOps = platformOps ?? PlatformOps.current();

  @override
  String? validate() => null;

  String _latest = inquiryVersion;
  String? _reason;

  /// Being current is the ordinary outcome, not a non-answer. Without this the
  /// framework would report `nothing would change`, which states the fact and
  /// withholds the only part worth reading.
  @override
  String? get nothingToDo => _reason;

  /// Two steps, and everything they need read before the plan is built.
  ///
  /// The releases API is asked **once**, here. That is what makes the plan
  /// honest: the version, the asset and the URL a person approves are the ones
  /// that get downloaded. Asking again inside the step could resolve a release
  /// published in the meantime, and the upgrade would not be the one shown.
  ///
  /// Nothing to upgrade to is not a failure, so it builds no steps and says
  /// why.
  @override
  Future<List<Step>> steps() async {
    final client = httpClientOverride ?? HttpClient();
    final Map<String, dynamic> release;
    try {
      final releaseUrl = Uri.parse(
        'https://api.github.com/repos/$_repo/releases/latest',
      );
      final metaRequest = await client.getUrl(releaseUrl);
      metaRequest.headers.set('Accept', 'application/vnd.github+json');
      metaRequest.headers.set('User-Agent', 'inquiry-cli/$inquiryVersion');
      final metaResponse = await metaRequest.close();

      if (metaResponse.statusCode != 200) {
        throw CommandException(
          id: 'release-lookup-failed',
          message:
              'Failed to fetch release info (HTTP ${metaResponse.statusCode})',
          exitCode: ExitCode.apiError,
        );
      }

      release =
          jsonDecode(await metaResponse.transform(utf8.decoder).join())
              as Map<String, dynamic>;
    } finally {
      if (httpClientOverride == null) client.close();
    }

    final tagName = release['tag_name'] as String;
    _latest = tagName.startsWith('v') ? tagName.substring(1) : tagName;
    if (_latest == inquiryVersion) {
      _reason = 'Already on the latest version';
      return const [];
    }

    final expectedAsset = platformOps.assetName;
    final asset = (release['assets'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .where((a) => a['name'] == expectedAsset)
        .firstOrNull;
    if (asset == null) {
      throw CommandException(
        id: 'asset-not-found',
        message: 'No $expectedAsset asset in release $tagName',
        exitCode: ExitCode.notFound,
      );
    }

    return [
      ReplaceInstallation(
        platformOps: platformOps,
        download: download,
        installDir: input.installDir,
        from: inquiryVersion,
        to: _latest,
        asset: expectedAsset,
        downloadUrl: asset['browser_download_url'] as String,
        progress: progress,
        runningExecutable: runningExecutable,
      ),
      RedeployHosts(
        platformOps: platformOps,
        installDir: input.installDir,
        progress: progress,
      ),
    ];
  }

  @override
  UpgradeOutput describe(Execution execution) {
    final deploy = execution.outcomes
        .where((o) => o.verb == 'deploy')
        .firstOrNull;
    return UpgradeOutput(
      previousVersion: inquiryVersion,
      newVersion: _latest,
      upgraded: execution.outcomes.any((o) => o.verb == 'replace'),
      deployed: deploy?.values['deployed'] as bool? ?? true,
      reason: _reason,
    );
  }
}

/// The child's combined output, trimmed and split — stdout first, then stderr.
///
/// `Process.run` buffers both; printing them is what lets a user see which
/// hosts were deployed to, or that none were. Blank lines are dropped so the
/// echoed block stays tight under `Deploying hosts...`.
///
/// Visible for testing.
List<String> postInstallOutputLines(ProcessResult result) => [
  '${result.stdout}',
  '${result.stderr}',
].expand((s) => s.split('\n')).map((l) => l.trimRight()).where((l) => l.isNotEmpty).toList(growable: false);
