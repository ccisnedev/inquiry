import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:modular_cli_sdk/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:inquiry_cli/modules/global/commands/upgrade.dart';
import 'package:inquiry_cli/src/version.dart';

import 'platform_ops_test.dart' show FakePlatformOps;

void main() {
  group('inquiry upgrade', () {
    test('UpgradeInput serializes correctly', () {
      final input = UpgradeInput(installDir: '/fake/dir');
      expect(input.toJson(), {'installDir': '/fake/dir'});
    });

    test('UpgradeOutput reports no upgrade when already latest', () {
      final output = UpgradeOutput(
        previousVersion: inquiryVersion,
        newVersion: inquiryVersion,
        upgraded: false,
        reason: 'Already on the latest version',
      );
      expect(output.exitCode, 0);
      expect(output.upgraded, isFalse);
      expect(output.toJson()['reason'], contains('latest'));
    });

    test('UpgradeOutput reports successful upgrade', () {
      final output = UpgradeOutput(
        previousVersion: '0.0.1',
        newVersion: '0.0.2',
        upgraded: true,
      );
      expect(output.exitCode, 0);
      expect(output.upgraded, isTrue);
      expect(output.previousVersion, '0.0.1');
      expect(output.newVersion, '0.0.2');
    });

    test('toText() returns checkmark message when upgraded', () {
      final output = UpgradeOutput(
        previousVersion: '0.0.1',
        newVersion: '0.0.2',
        upgraded: true,
      );
      expect(output.toText(), contains('✓'));
      expect(output.toText(), contains('0.0.1'));
      expect(output.toText(), contains('0.0.2'));
    });

    test('toText() returns plain message when not upgraded', () {
      final output = UpgradeOutput(
        previousVersion: '0.0.2',
        newVersion: '0.0.2',
        upgraded: false,
        reason: 'Already on the latest version',
      );
      expect(output.toText(), equals('Already on the latest version'));
    });

    // The upgrade succeeded; only the redeploy did not. Saying so is the whole
    // point of `deployed` being separate from `upgraded` — a failed redeploy
    // must not read as a failed upgrade.
    test('toText() points at `iq host get` when the redeploy was skipped', () {
      final output = UpgradeOutput(
        previousVersion: '0.0.1',
        newVersion: '0.0.2',
        upgraded: true,
        deployed: false,
      );
      expect(output.toText(), contains('✓ Upgraded'));
      expect(output.toText(), contains('iq host get'));
    });
  });

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

  // What `--plan` shows. An upgrade replaces the binary the user is running
  // from, so the version it would move to, the asset it would fetch and the URL
  // it would fetch it from are exactly what a person needs before approving.
  group('inquiry upgrade under --plan', () {
    UpgradeCommand upgradeTo(
      String tag, {
      required _FakeReleasesClient client,
      FakePlatformOps? ops,
      Downloader? download,
    }) => UpgradeCommand(
      UpgradeInput(installDir: '/fake/dir'),
      platformOps: ops ?? FakePlatformOps(),
      httpClientOverride: client,
      download: download ?? (url, destination) async {},
      progress: _NullSink(),
      runningExecutable: '/fake/dir/bin/never-touched',
    );

    test('names the replacement, with version, asset and URL', () async {
      final client = _FakeReleasesClient(
        tag: 'v9.9.9',
        assets: {'ape-fake.zip': 'https://example.test/ape-fake.zip'},
      );

      final previews = await previewCommand(upgradeTo('v9.9.9', client: client));

      expect(previews.map((p) => p.verb).toList(), ['replace', 'deploy']);
      expect(previews.first.detail, contains('$inquiryVersion → 9.9.9'));
      expect(previews.first.detail, contains('ape-fake.zip'));
      expect(previews.first.detail, contains('https://example.test/'));
    });

    // The honesty of the plan rests on this: the version, asset and URL a
    // person approves are the ones downloaded. A second lookup at perform time
    // could resolve a release published in between.
    test('asks the releases API once, when the plan is built', () async {
      final client = _FakeReleasesClient(
        tag: 'v9.9.9',
        assets: {'ape-fake.zip': 'https://example.test/ape-fake.zip'},
      );

      await previewCommand(upgradeTo('v9.9.9', client: client));

      expect(client.calls, 1);
    });

    test('touches nothing: no download, no extraction', () async {
      final ops = FakePlatformOps();
      var downloads = 0;
      final client = _FakeReleasesClient(
        tag: 'v9.9.9',
        assets: {'ape-fake.zip': 'https://example.test/ape-fake.zip'},
      );

      await previewCommand(
        upgradeTo(
          'v9.9.9',
          client: client,
          ops: ops,
          download: (url, destination) async => downloads++,
        ),
      );

      expect(downloads, 0);
      expect(ops.calls, isEmpty);
    });

    // Nothing to upgrade to is an answer, not a failure: no steps, and a
    // reason.
    test('plans nothing when already on the latest version', () async {
      final client = _FakeReleasesClient(
        tag: 'v$inquiryVersion',
        assets: {'ape-fake.zip': 'https://example.test/ape-fake.zip'},
      );
      final command = upgradeTo('v$inquiryVersion', client: client);

      expect(await previewCommand(command), isEmpty);

      final output = await applyCommand(command);
      expect(output.upgraded, isFalse);
      expect(output.toText(), contains('Already on the latest version'));
    });

    test('refuses a release that carries no asset for this platform', () async {
      final client = _FakeReleasesClient(
        tag: 'v9.9.9',
        assets: {'some-other-platform.zip': 'https://example.test/other.zip'},
      );

      expect(
        () => previewCommand(upgradeTo('v9.9.9', client: client)),
        throwsA(
          predicate((e) => e.toString().contains('ape-fake.zip')),
        ),
      );
    });
  });

  group('inquiry upgrade under --apply', () {
    test('reports the redeploy separately from the upgrade itself', () async {
      // A real directory with a real binary in it: on Windows the step moves
      // the running executable aside before extracting over it, and
      // `runningExecutable` is injected precisely so that binary is this
      // throwaway file and never the Dart VM running the suite.
      final installDir = Directory.systemTemp.createTempSync('iq_upgrade_');
      addTearDown(() {
        if (installDir.existsSync()) installDir.deleteSync(recursive: true);
      });
      final binary = File(p.join(installDir.path, 'bin', 'inquiry.exe'))
        ..createSync(recursive: true)
        ..writeAsStringSync('the outgoing binary');

      final ops = FakePlatformOps()
        ..postInstallResult = ProcessResult(0, 1, '', 'no host');
      final client = _FakeReleasesClient(
        tag: 'v9.9.9',
        assets: {'ape-fake.zip': 'https://example.test/ape-fake.zip'},
      );

      final output = await applyCommand(
        UpgradeCommand(
          UpgradeInput(installDir: installDir.path),
          platformOps: ops,
          httpClientOverride: client,
          download: (url, destination) async =>
              File(destination).writeAsStringSync('archive'),
          progress: _NullSink(),
          runningExecutable: binary.path,
        ),
      );

      expect(output.upgraded, isTrue);
      expect(output.newVersion, '9.9.9');
      expect(output.deployed, isFalse, reason: 'the child exited non-zero');
      expect(output.toText(), contains('iq host get'));
    });
  });
}

/// Discards the steps' running commentary, which is stderr in production.
class _NullSink implements IOSink {
  @override
  void writeln([Object? object = '']) {}

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Serves one canned GitHub releases payload, and counts how often it is asked.
class _FakeReleasesClient implements HttpClient {
  _FakeReleasesClient({required this.tag, required this.assets});

  final String tag;
  final Map<String, String> assets;

  /// How many times the releases API was reached. The plan is only as honest
  /// as this number is 1.
  int calls = 0;

  String get _body => jsonEncode({
    'tag_name': tag,
    'assets': [
      for (final entry in assets.entries)
        {'name': entry.key, 'browser_download_url': entry.value},
    ],
  });

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    calls++;
    return _FakeRequest(_FakeResponse(_body));
  }

  @override
  void close({bool force = false}) {}

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this._response);

  final HttpClientResponse _response;

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  Future<HttpClientResponse> close() async => _response;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHeaders implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this.body);

  final String body;

  @override
  int get statusCode => 200;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(utf8.encode(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
