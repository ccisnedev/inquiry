import 'dart:convert';

import 'package:cli_router/cli_router.dart' show CliRequest;
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import 'support/string_io_sink.dart';

/// `cli_router` 0.2.1 accepts options after operands (GNU permutation) by
/// default and falls back to strict POSIX order when `POSIXLY_CORRECT` is
/// set in the environment. `modular_cli_sdk` 0.8.1 requires that version and
/// forwards an optional `environment` map from `ModularCli.run` to the
/// router, so a caller can pick either ordering without touching the real
/// process environment.
///
/// This exercises that behavior directly against [ModularCli] rather than
/// through `runInquiry`: no `iq` command declares a positional today (see
/// the note at the bottom of `cli_contract_test.dart` — that coverage lives
/// in macss), so there is no shipped `iq` invocation that has both an
/// operand and an option to reorder. The router and the SDK version this
/// asserts against are exactly the ones `runInquiry` runs on top of
/// (`pubspec.yaml`'s `modular_cli_sdk`/`cli_router` pins), so this is a real
/// exercise of the dependency this CLI ships, not a mock of it.
class _InspectInput extends Input {
  _InspectInput({required this.issue, required this.verbose});

  final int issue;
  final bool verbose;

  static final contract = CliContract(
    positionals: [CliPositional.integer('issue', required: true)],
    options: [CliParam.flag('verbose', abbr: null, repeatable: false)],
  );

  factory _InspectInput.fromCliRequest(CliRequest req) => _InspectInput(
    issue: req.positionalInt('issue')!,
    verbose: req.flagBool('verbose'),
  );

  @override
  Map<String, dynamic> toJson() => {'issue': issue, 'verbose': verbose};
}

class _InspectOutput extends Output {
  _InspectOutput(this.issue, this.verbose);

  final int issue;
  final bool verbose;

  @override
  Map<String, dynamic> toJson() => {'issue': issue, 'verbose': verbose};

  @override
  int get exitCode => ExitCode.ok;
}

class _InspectQuery implements Query<_InspectInput, _InspectOutput> {
  _InspectQuery(this.input);

  @override
  final _InspectInput input;

  @override
  String? validate() => null;

  @override
  Future<_InspectOutput> execute() async =>
      _InspectOutput(input.issue, input.verbose);
}

ModularCli _buildCli() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_InspectInput, _InspectOutput>(
    'inspect <issue>',
    (req) => _InspectQuery(_InspectInput.fromCliRequest(req)),
    globals: true,
    description: 'Inspect one issue, for option-ordering coverage',
    contract: _InspectInput.contract,
  );
  return cli;
}

Future<({int code, String out, String err})> _run(
  List<String> args, {
  required Map<String, String> environment,
}) async {
  final out = StringIOSink();
  final err = StringIOSink();
  final code = await _buildCli().run(
    args,
    stdout: out,
    stderr: err,
    environment: environment,
  );
  return (code: code, out: out.toString(), err: err.toString());
}

void main() {
  group('option ordering (cli_router 0.2.1 GNU permutation)', () {
    test(
      'an option after the operand is accepted with the default environment',
      () async {
        final r = await _run(
          const ['inspect', '--json', '40', '--verbose'],
          environment: const {},
        );

        expect(r.code, ExitCode.ok);
        final data = jsonDecode(r.out) as Map<String, dynamic>;
        expect(data['issue'], 40);
        expect(data['verbose'], isTrue);
      },
    );

    test(
      'POSIXLY_CORRECT rejects the same option-after-operand invocation as '
      'misplaced-option',
      () async {
        final r = await _run(
          const ['inspect', '--json', '40', '--verbose'],
          environment: const {'POSIXLY_CORRECT': '1'},
        );

        expect(r.code, ExitCode.validationFailed);
        final envelope = jsonDecode(r.err) as Map<String, dynamic>;
        final error = envelope['error'] as Map<String, dynamic>;
        expect(error['id'], 'misplaced-option');
      },
    );

    test(
      'POSIXLY_CORRECT still accepts the option before the operand',
      () async {
        final r = await _run(
          const ['inspect', '--json', '--verbose', '40'],
          environment: const {'POSIXLY_CORRECT': '1'},
        );

        expect(r.code, ExitCode.ok);
      },
    );
  });
}
