import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('CLI scaffold', () {
    test('responds to a registered query with exit code 0', () async {
      final cli = ModularCli(suggestionDistance: 2);
      cli.query<PingInput, PingOutput>(
        'ping',
        (req) => PingQuery(PingInput.fromCliRequest(req)),
        description: 'Ping test',
        globals: true,
        contract: PingInput.contract,
      );

      final code = await cli.run(['ping']);
      expect(code, ExitCode.ok);
    });

    // A query answers on the spot; a command does not. The scaffold has to
    // dispatch both kinds, and the difference between them is the whole point
    // of registering them apart — so it belongs in the scaffold's own test.
    test(
      'refuses a registered command that names neither --plan nor --apply',
      () async {
        final cli = ModularCli(suggestionDistance: 2);
        cli.command<PingInput, PingOutput>(
          'touch',
          (req) => PingCommand(PingInput.fromCliRequest(req)),
          description: 'Command test',
          globals: true,
          contract: PingInput.contract,
        );

        final code = await cli.run(['touch']);
        expect(code, ExitCode.validationFailed);
      },
    );

    test('runs a registered command under --plan', () async {
      final cli = ModularCli(suggestionDistance: 2);
      cli.command<PingInput, PingOutput>(
        'touch',
        (req) => PingCommand(PingInput.fromCliRequest(req)),
        description: 'Command test',
        globals: true,
        contract: PingInput.contract,
      );

      final code = await cli.run(['touch', '--plan']);
      expect(code, ExitCode.ok);
    });

    test('returns exit code 64 for unknown command', () async {
      final cli = ModularCli(suggestionDistance: 2);

      final code = await cli.run(['nonexistent']);
      expect(code, ExitCode.invalidUsage);
    });
  });
}

// ─── Dummy routes for scaffold validation ───────────────────────────────────

class PingInput extends Input {
  PingInput();
  factory PingInput.fromCliRequest(CliRequest req) => PingInput();

  static const CliContract contract = CliContract.none;

  @override
  Map<String, dynamic> toJson() => {};
}

class PingOutput extends Output {
  PingOutput();

  @override
  Map<String, dynamic> toJson() => {'pong': true};

  @override
  int get exitCode => ExitCode.ok;
}

class PingQuery implements Query<PingInput, PingOutput> {
  @override
  final PingInput input;
  PingQuery(this.input);

  @override
  String? validate() => null;

  @override
  Future<PingOutput> execute() async => PingOutput();
}

class PingCommand implements Command<PingInput, PingOutput> {
  @override
  final PingInput input;
  PingCommand(this.input);

  @override
  String? validate() => null;

  @override
  Future<List<Step>> steps() async => [PingStep()];

  @override
  PingOutput describe(Execution execution) => PingOutput();
}

class PingStep implements Step {
  @override
  Preview preview() => Preview(verb: 'ping', target: 'nothing at all');

  @override
  Future<Outcome> perform(StepContext context) async =>
      Outcome(verb: 'ping', target: 'nothing at all');
}
