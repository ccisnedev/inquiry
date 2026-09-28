import 'package:inquiry_cli/inquiry_cli.dart';
import 'package:test/test.dart';

import 'support/string_io_sink.dart';

/// The help is the SDK's — `modular_cli_sdk` renders it from the command
/// catalog every registration feeds. Inquiry maintains no help text of its own:
/// the hand-written one drifted, and two modules once shipped without ever
/// appearing in it.
Future<({int code, String out, String err})> _run(List<String> args) async {
  final out = StringIOSink();
  final err = StringIOSink();
  final code = await runInquiry(args, stdout: out, stderr: err);
  return (code: code, out: out.toString(), err: err.toString());
}

void main() {
  group('inquiry help', () {
    test('lists every registered command', () async {
      final r = await _run(const ['help']);

      const registered = [
        'init',
        'version',
        'doctor',
        'upgrade',
        'uninstall',
        'host get',
        'host clean',
        'fsm state',
        'fsm transition',
        'ape prompt',
        'ape state',
        'ape transition',
        'implementation start',
      ];

      expect(r.code, 0);
      expect(r.err, isEmpty);
      for (final route in registered) {
        expect(
          r.out,
          contains(route),
          reason: '`$route` is registered but missing from the help',
        );
      }
    });

    test(
      'names the TUI by how it is invoked, and documents global options',
      () async {
        final r = await _run(const ['help']);

        expect(r.out, contains('(no arguments)'));
        expect(r.out, contains('Global options'));
      },
    );

    test('carries each command description, not just its route', () async {
      final r = await _run(const ['help']);

      // `version`'s description is `VersionPlugin`'s own, not Inquiry's
      // (ccisnedev/inquiry#321).
      expect(r.out, contains("Print this CLI's name and version"));
      expect(r.out, contains('Run a deterministic FSM transition'));
    });

    /// The lifecycle commands moved to MACSS; the help must not keep offering
    /// them, or users are pointed at routes that no longer exist.
    test('no longer advertises the migrated lifecycle commands', () async {
      final r = await _run(const ['help']);

      // Matched at the start of a line, where a route name sits. The bare word
      // is not enough: `skill validate` describes itself as checking skills
      // against the Agent Skills *specification*, and prose is not a route.
      for (final gone in ['specification', 'issue new', 'issue publish']) {
        expect(
          r.out,
          isNot(matches(RegExp('^[ ]+$gone\b', multiLine: true))),
          reason: '`\$gone` moved to macss and must not appear as an iq route',
        );
      }
    });

    test('and it does advertise the shared skill module', () async {
      final r = await _run(const ['help']);
      for (final route in ['skill list', 'skill doctor', 'skill validate']) {
        expect(r.out, contains(route));
      }
    });

    /// Every deliberate help request is a success on stdout — never an error.
    for (final args in [
      ['help'],
      ['--help'],
      ['-h'],
    ]) {
      test('`iq ${args.join(' ')}` prints help on stdout, exit 0', () async {
        final r = await _run(args);

        expect(r.code, 0);
        expect(r.err, isEmpty);
        expect(r.out, contains('Global options'));
      });
    }

    /// `iq` with no arguments is NOT a help request — it is a registered route:
    /// the banner + FSM diagram.
    test('bare `iq` runs the TUI, not the help', () async {
      final r = await _run(const []);

      expect(r.code, 0);
      expect(r.out, contains('Inquiry'), reason: 'the banner should print');
      expect(
        r.out,
        contains('Analyze'),
        reason: 'the FSM diagram should print',
      );
      expect(
        r.out,
        isNot(contains('Global options')),
        reason: 'the empty invocation was hijacked by the help',
      );
    });

    test('normalizes the version flags to the version command', () {
      expect(
        normalizeInquiryArgs(const ['--version']),
        equals(const ['version']),
      );
      expect(normalizeInquiryArgs(const ['-v']), equals(const ['version']));
      expect(
        normalizeInquiryArgs(const ['fsm', 'state']),
        equals(const ['fsm', 'state']),
      );
    });
  });
}
