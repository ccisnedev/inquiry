/// `iq ape transition --event <e>` — validates and executes APE internal transition.
library;

import 'dart:io';

import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:path/path.dart' as p;

import '../../../assets.dart';
import '../ape_definition.dart';
import '../inquiry_state.dart';

// ─── Input ──────────────────────────────────────────────────────────────────

class ApeTransitionInput extends Input {
  final String? event;
  final String workingDirectory;

  ApeTransitionInput({required this.event, required this.workingDirectory});

  static final CliContract contract = CliContract(
    options: [
      CliParam.string(
        'event',
        abbr: 'e',
        required: true,
        repeatable: false,
        defaultValue: null,
        description: 'The APE-internal transition to execute',
      ),
    ],
  );

  factory ApeTransitionInput.fromCliRequest(CliRequest req) {
    return ApeTransitionInput(
      event: req.flagString('event'),
      workingDirectory: Directory.current.path,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
    if (event != null) 'event': event,
    'workingDirectory': workingDirectory,
  };
}

// ─── Output ─────────────────────────────────────────────────────────────────

class ApeTransitionOutput extends Output {
  final String apeName;
  final String from;
  final String event;
  final String to;

  ApeTransitionOutput({
    required this.apeName,
    required this.from,
    required this.event,
    required this.to,
  });

  @override
  Map<String, dynamic> toJson() => {
    'ape': apeName,
    'from': from,
    'event': event,
    'to': to,
  };

  @override
  int get exitCode => ExitCode.ok;

  @override
  String? toText() => '$apeName: $from --$event--> $to';
}

// ─── Command ────────────────────────────────────────────────────────────────

class ApeTransitionCommand
    implements Query<ApeTransitionInput, ApeTransitionOutput> {
  @override
  final ApeTransitionInput input;
  final Assets? _assets;

  ApeTransitionCommand(this.input, {Assets? assets}) : _assets = assets;

  @override
  String? validate() => null;

  @override
  Future<ApeTransitionOutput> execute() async {
    if (input.event == null || input.event!.trim().isEmpty) {
      throw CommandException(
        id: 'missing-event',
        message:
            'Missing required flag --event. Usage: iq ape transition --event <event>',
        exitCode: ExitCode.validationFailed,
      );
    }
    final inquiryState = InquiryState.load(input.workingDirectory);

    if (inquiryState.apeName == null) {
      throw CommandException(
        id: 'no-active-ape',
        message: 'No APE is active in state ${inquiryState.state}',
        exitCode: ExitCode.conflict,
      );
    }

    final currentApeState = inquiryState.apeState;
    if (currentApeState == '_DONE') {
      throw CommandException(
        id: 'ape-completed',
        message:
            '"${inquiryState.apeName}" has already completed (_DONE). '
            'Transition the main FSM to advance.',
        exitCode: ExitCode.conflict,
      );
    }

    // Load APE definition
    final yamlPath = _resolveApePath(inquiryState.apeName!);
    final yamlFile = File(yamlPath);
    if (!yamlFile.existsSync()) {
      throw CommandException(
        id: 'ape-not-found',
        message: 'No definition for "${inquiryState.apeName}" at $yamlPath',
        exitCode: ExitCode.notFound,
      );
    }

    final definition = ApeDefinition.parse(yamlFile.readAsStringSync());
    final fromState = currentApeState ?? definition.initialState;
    final stateObj = definition.findState(fromState);

    if (stateObj == null) {
      throw CommandException(
        id: 'invalid-ape-state',
        message: '"${inquiryState.apeName}" has no state "$fromState"',
        exitCode: ExitCode.conflict,
      );
    }

    // Find matching transition
    ApeTransition? match;
    for (final t in stateObj.transitions) {
      if (t.event == input.event!) {
        match = t;
        break;
      }
    }

    if (match == null) {
      final valid = stateObj.transitions.map((t) => t.event).join(', ');
      throw CommandException(
        id: 'invalid-ape-event',
        message:
            '"${input.event}" is not valid from '
            '"${inquiryState.apeName}:$fromState". Valid events: [$valid]',
        exitCode: ExitCode.validationFailed,
      );
    }

    // Write the new sub-state
    final newState = inquiryState.copyWith(apeState: match.to);
    newState.save(input.workingDirectory);

    return ApeTransitionOutput(
      apeName: inquiryState.apeName!,
      from: fromState,
      event: input.event!,
      to: match.to,
    );
  }

  String _resolveApePath(String name) {
    if (_assets != null) {
      return _assets.path('apes/$name.yaml');
    }
    return p.join(input.workingDirectory, 'assets', 'apes', '$name.yaml');
  }
}
