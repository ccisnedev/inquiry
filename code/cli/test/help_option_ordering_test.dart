import 'package:inquiry_cli/inquiry_cli.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import 'support/string_io_sink.dart';

/// `cli_router` 0.2.1 accepts an option written after an operand (GNU
/// permutation) by default, and rejects it as `misplaced-option` when
/// `POSIXLY_CORRECT` is set in the environment. `runInquiry` forwards its own
/// optional `environment` map to `ModularCli.run`, so a caller, this test
/// included, can pick either ordering without touching the real process
/// environment.
///
/// The real command exercised here is `iq help`: inquiry registers no `help`
/// route of its own, so every `iq help ...` invocation reaches the SDK's
/// built-in `help *` wildcard route, which takes the topic words as an
/// operand. It is the only operand-bearing route this CLI mounts today (see
/// the note at the bottom of `cli_contract_test.dart`; `<param>` positional
/// coverage lives in macss).
///
/// A wildcard route is not, however, a plain operand for `cli_router`'s
/// permutation rewrite: past the wildcard's own first captured operand,
/// nothing is read as an option again, by design (`cli_router`'s own
/// `_normalizeForPermute` docs: "an invocation like `docker run IMAGE CMD
/// -flags` reaches the wildcard with its flags intact, as data"). So
/// `--quiet` written after the topic is still accepted in default mode
/// (exit code 0, no `misplaced-option`), exactly as the issue asks, but it
/// is folded into the help topic text instead of taking effect, which
/// changes `iq help --json fsm --quiet`'s output from the scoped `fsm`
/// listing to the full, unscoped catalog. That is real, verified behavior
/// (`help fsm --json`/`help fsm --quiet` both fall back to the full catalog
/// the same way), not a bug introduced by this change, so this test asserts
/// what actually holds for a wildcard route: the permuted invocation is
/// accepted with the same exit code as canonical and never produces
/// `misplaced-option`, and the strict invocation is rejected as
/// `misplaced-option`. Byte-identical stdout between the two default-mode
/// orderings is not asserted, because it does not hold for this route; the
/// synthetic `inspect <issue>` route in `option_ordering_test.dart` covers
/// that full content-equivalence, which only a non-wildcard positional can
/// demonstrate.
Future<({int code, String out, String err})> _run(
  List<String> args, {
  required Map<String, String> environment,
}) async {
  final out = StringIOSink();
  final err = StringIOSink();
  final code = await runInquiry(
    args,
    stdout: out,
    stderr: err,
    environment: environment,
  );
  return (code: code, out: out.toString(), err: err.toString());
}

void main() {
  group('iq help option ordering (cli_router 0.2.1 GNU permutation)', () {
    test(
      'the canonical order (options before the topic) is accepted and scoped',
      () async {
        final r = await _run(const [
          'help',
          '--json',
          '--quiet',
          'fsm',
        ], environment: const {});

        expect(r.code, ExitCode.ok);
        expect(r.out, contains('"route": "fsm state"'));
        expect(r.out, contains('"route": "fsm transition"'));
        expect(r.err, isEmpty);
      },
    );

    test(
      'an option written after the topic is still accepted by default, '
      'with the same exit code as canonical and no misplaced-option',
      () async {
        final canonical = await _run(const [
          'help',
          '--json',
          '--quiet',
          'fsm',
        ], environment: const {});
        final permuted = await _run(const [
          'help',
          '--json',
          'fsm',
          '--quiet',
        ], environment: const {});

        expect(permuted.code, ExitCode.ok);
        expect(permuted.code, canonical.code);
        expect(permuted.err, isNot(contains('misplaced-option')));
      },
    );

    test('POSIXLY_CORRECT rejects the same topic-then-option invocation as '
        'misplaced-option', () async {
      final r = await _run(
        const ['help', '--json', 'fsm', '--quiet'],
        environment: const {'POSIXLY_CORRECT': '1'},
      );

      expect(r.code, ExitCode.validationFailed);
      expect(r.err, contains('misplaced-option'));
    });

    test(
      'POSIXLY_CORRECT still accepts every option before the topic',
      () async {
        final r = await _run(
          const ['help', '--json', '--quiet', 'fsm'],
          environment: const {'POSIXLY_CORRECT': '1'},
        );

        expect(r.code, ExitCode.ok);
      },
    );
  });
}
