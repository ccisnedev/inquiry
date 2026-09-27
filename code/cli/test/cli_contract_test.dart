import 'dart:convert';

import 'package:inquiry_cli/inquiry_cli.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import 'support/string_io_sink.dart';

/// Every `iq` command declares its parameters, so the help *is* the contract and
/// the contract *is* what gets parsed — they cannot drift. An option the command
/// never declared is refused instead of silently ignored, which is how
/// `iq init --host claude` used to run while doing nothing the flag implied.
Future<({int code, String out, String err})> _run(List<String> args) async {
  final out = StringIOSink();
  final err = StringIOSink();
  final code = await runInquiry(args, stdout: out, stderr: err);
  return (code: code, out: out.toString(), err: err.toString());
}

void main() {
  group('a command refuses what it never declared', () {
    test(
      '`iq init --host claude` is rejected, not silently accepted',
      () async {
        final r = await _run(const ['init', '--host', 'claude']);

        expect(r.code, ExitCode.validationFailed);
        // cli_router 0.2.0 quotes the option name and appends an error id tag.
        expect(r.err, contains("unknown option '--host'"));
      },
    );

    test('`iq implementation start --bogus x` is rejected', () async {
      final r = await _run(const ['implementation', 'start', '--bogus', 'x']);

      expect(r.code, ExitCode.validationFailed);
      expect(r.err, contains("unknown option '--bogus'"));
    });

    test('the global options stay accepted everywhere', () async {
      final r = await _run(const ['version', '--json']);

      expect(r.code, 0);
      expect(jsonDecode(r.out), isA<Map<String, dynamic>>());
    });
  });

  group('the help renders each command contract', () {
    test(
      '`iq fsm transition --help` shows --event and its allowed values',
      () async {
        final r = await _run(const ['fsm', 'transition', '--help']);

        expect(r.code, 0);
        expect(r.out, contains('--event'));
        expect(r.out, contains('complete_analysis'));
        expect(r.out, contains('approve_plan'));
      },
    );

    test('`iq host get --help` shows the allowed hosts', () async {
      final r = await _run(const ['host', 'get', '--help']);

      expect(r.code, 0);
      expect(r.out, contains('--host'));
      expect(r.out, contains('opencode'));
      expect(r.out, contains('claude'));
    });

    test('`iq fsm --help` describes every command in the module', () async {
      final r = await _run(const ['fsm', '--help']);

      expect(r.code, 0);
      expect(r.out, contains('fsm state'));
      expect(r.out, contains('fsm transition'));
      expect(r.out, contains('--event'));
    });
  });

  group('iq help --json is the machine-readable contract', () {
    test('every command appears with its declared parameters', () async {
      final r = await _run(const ['help', '--json']);

      expect(r.code, 0);
      final catalog = jsonDecode(r.out) as Map<String, dynamic>;
      final commands = (catalog['commands'] as List)
          .cast<Map<String, dynamic>>();
      final routes = commands.map((c) => c['route']).toList();

      expect(routes, contains('fsm transition'));
      expect(routes, contains('implementation start'));

      // A declared `allowed` set reaches the machine contract, not just the help
      // text: this is what lets a caller enumerate the legal events.
      // modular_cli_sdk 0.6.0 renamed the declared-options key from `params`
      // to `options` (`CliContract.toJson()`).
      final transition = commands.firstWhere(
        (c) => c['route'] == 'fsm transition',
      );
      final options = (transition['options'] as List)
          .cast<Map<String, dynamic>>();
      final event = options.firstWhere((p) => p['name'] == 'event');

      expect(
        event['allowed'],
        containsAll(<String>['complete_analysis', 'approve_plan']),
      );

      // Param types reach it too, so a caller can tell a flag from an
      // option: every declared option's `kind` is now `'option'`
      // (`CliParam.toJson()`), so a flag is told apart by its `type` instead.
      final hostGet = commands.firstWhere((c) => c['route'] == 'host get');
      final hostOptions = (hostGet['options'] as List)
          .cast<Map<String, dynamic>>();
      expect(
        hostOptions.firstWhere((p) => p['name'] == 'configure-ollama')['type'],
        'flag',
      );
      // `--host` deliberately carries no default: defaulting to one made
      // `iq host get` deploy to a host the user might not have (#300).
      expect(
        hostOptions.firstWhere((p) => p['name'] == 'host')['default'],
        isNull,
      );

      // Defaults and positionals are no longer exercised here: no inquiry
      // command declares either. That coverage lives in macss.
    });
  });
}
