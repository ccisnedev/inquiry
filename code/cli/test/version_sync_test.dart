import 'dart:io';

import 'package:inquiry_cli/src/version.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  late String yamlVersion;
  late String webVersion;

  setUpAll(() {
    // pubspec.yaml
    final pubspecFile = File('pubspec.yaml');
    expect(
      pubspecFile.existsSync(),
      isTrue,
      reason: 'pubspec.yaml must exist — run tests from code/cli/',
    );
    final pubspec = loadYaml(pubspecFile.readAsStringSync()) as Map;
    yamlVersion = pubspec['version'].toString();

    // site index.html badge
    final indexFile = File('../../code/site/index.html');
    expect(
      indexFile.existsSync(),
      isTrue,
      reason: 'code/site/index.html must exist',
    );
    final html = indexFile.readAsStringSync();
    final match = RegExp(r'class="badge">v(\d+\.\d+\.\d+)').firstMatch(html);
    expect(match, isNotNull, reason: 'index.html must contain a version badge');
    webVersion = match!.group(1)!;
  });

  test('version.dart matches pubspec.yaml', () {
    expect(
      inquiryVersion,
      equals(yamlVersion),
      reason:
          'version.dart ($inquiryVersion) != pubspec.yaml ($yamlVersion). '
          'Fix: update code/cli/lib/src/version.dart OR code/cli/pubspec.yaml',
    );
  });

  test('site index.html badge matches version.dart', () {
    expect(
      webVersion,
      equals(inquiryVersion),
      reason:
          'index.html badge (v$webVersion) != version.dart ($inquiryVersion). '
          'Fix: update <span class="badge"> in code/site/index.html',
    );
  });

  test('all three version sources are consistent', () {
    final sources = {
      'code/cli/pubspec.yaml': yamlVersion,
      'code/cli/lib/src/version.dart': inquiryVersion,
      'code/site/index.html badge': webVersion,
    };
    final unique = sources.values.toSet();
    expect(
      unique.length,
      equals(1),
      reason:
          'All version sources must match but found: '
          '${sources.entries.map((e) => '${e.key}=${e.value}').join(', ')}',
    );
  });
}
