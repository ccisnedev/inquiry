library;

import 'dart:convert';
import 'dart:io';

import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../../../assets.dart';
import '../../../fsm_contract.dart';
import '../../../src/cycle_context.dart';
import '../../ape/ape_definition.dart';
import '../../ape/inquiry_state.dart';
import '../../ape/operational_contract.dart';

class FsmStateInput extends Input {
  final String workingDirectory;

  FsmStateInput({required this.workingDirectory});

  factory FsmStateInput.fromCliRequest(CliRequest req) {
    return FsmStateInput(workingDirectory: Directory.current.path);
  }

  /// Declares an EMPTY contract: this command accepts no option at all, so any
  /// option passed to it is refused.
  static const CliContract contract = CliContract.none;

  @override
  Map<String, dynamic> toJson() => {'workingDirectory': workingDirectory};
}

class FsmStateOutput extends Output {
  final String state;
  final String? issue;
  final List<Map<String, String>> transitions;
  final List<Map<String, String>> apes;
  final String instructions;
  final Map<String, dynamic> operationalContract;
  final Map<String, dynamic>? ape;
  final String completionAuthority;

  /// The single next action the CLI prescribes — the model executes it, it does
  /// not decide. When a real choice is due, this hands the decision to the
  /// human (#270).
  final String next;

  FsmStateOutput({
    required this.state,
    required this.issue,
    required this.transitions,
    required this.apes,
    required this.instructions,
    required this.operationalContract,
    this.ape,
    required this.completionAuthority,
    required this.next,
  });

  @override
  Map<String, dynamic> toJson() => {
    'state': state,
    'issue': issue,
    'completion_authority': completionAuthority,
    'next': next,
    'transitions': transitions,
    'apes': apes,
    'instructions': instructions,
    'operational_contract': operationalContract,
    if (ape != null) 'ape': ape,
  };

  @override
  int get exitCode => 0;

  @override
  String? toText() {
    final buf = StringBuffer();
    buf.writeln('State: $state');
    if (issue != null) buf.writeln('Issue: $issue');

    if (apes.isNotEmpty) {
      buf.writeln('APEs:  ${apes.map((a) => a['name']).join(', ')}');
    }

    buf.writeln('Next:  $next');

    if (transitions.isNotEmpty) {
      buf.writeln('Valid transitions:');
      for (final t in transitions) {
        buf.writeln('  --${t['event']}');
      }
    }
    return buf.toString().trimRight();
  }

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());
}

class FsmStateCommand implements Query<FsmStateInput, FsmStateOutput> {
  @override
  final FsmStateInput input;
  final Assets? _assets;

  FsmStateCommand(this.input, {Assets? assets}) : _assets = assets;

  @override
  String? validate() => null;

  @override
  Future<FsmStateOutput> execute() async {
    final inquiry = InquiryState.load(input.workingDirectory);
    final currentState = FsmState.fromValue(inquiry.state.trim().toUpperCase());

    final contractPath = _assets != null
        ? _assets.path('fsm/transition_contract.yaml')
        : p.join(
            input.workingDirectory,
            'assets',
            'fsm',
            'transition_contract.yaml',
          );
    final contract = parseFsmContract(File(contractPath).readAsStringSync());

    final validTransitions = _computeTransitions(
      contract,
      currentState,
      input.workingDirectory,
    );
    final activeApes = _computeApes(currentState);
    final operationalContract = _loadOperationalContract(currentState);
    final instructions = operationalContract.instructions;
    final apeInfo = _computeApeInfo(inquiry);
    final completionAuthority =
        contract.completionAuthority[currentState] ?? 'user';

    return FsmStateOutput(
      state: currentState.value,
      issue: inquiry.issue,
      transitions: validTransitions,
      apes: activeApes,
      instructions: instructions,
      operationalContract: operationalContract.toJson(),
      ape: apeInfo,
      completionAuthority: completionAuthority,
      next: _computeNext(validTransitions, apeInfo, completionAuthority),
    );
  }

  /// Computes the single next action the model should take. The model never
  /// chooses an event or a path — the CLI does; genuine choices are handed to
  /// the human (#270).
  String _computeNext(
    List<Map<String, String>> transitions,
    Map<String, dynamic>? apeInfo,
    String completionAuthority,
  ) {
    // 1. An operator is still working: dispatch it; do not transition yet.
    if (apeInfo != null && apeInfo['state'] != '_DONE') {
      final name = apeInfo['name'];
      final apeEvents = ((apeInfo['transitions'] as List?) ?? const [])
          .map((t) => (t as Map)['event'] as String)
          .where((e) => e != 'block')
          .toList(growable: false);
      final after = apeEvents.length == 1
          ? ' Then run `iq ape transition --event ${apeEvents.first}`.'
          : ' Then advance the operator with `iq ape transition` and re-run `iq fsm state --json` for the next step.';
      return 'Run `iq ape prompt --name $name`, dispatch a write-capable '
          'sub-agent with that prompt; it MUST write the phase deliverable '
          'before you continue.$after Do not transition the main FSM yet.';
    }

    // 2. At a main-FSM transition point.
    final forward = transitions
        .map((t) => t['event']!)
        .where((e) => e != 'block')
        .toList(growable: false);
    if (forward.isEmpty) {
      return 'No forward transition is available from this state. '
          'Run `iq doctor` if you are stuck.';
    }
    if (forward.length > 1) {
      return 'DECISION FOR THE HUMAN: multiple paths are available '
          '(${forward.join(', ')}). Present the situation and the options to '
          'the human and let them choose — do not decide yourself.';
    }
    final event = forward.first;
    if (completionAuthority == 'user') {
      return 'STOP — the deliverable is ready. Present it to the human and ask '
          'them to approve the transition `$event`. The human decides — do not '
          'run the transition yourself.';
    }
    return 'Run `iq fsm transition --event $event`.';
  }

  List<Map<String, String>> _computeTransitions(
    FsmContract contract,
    FsmState state,
    String workingDirectory,
  ) {
    final result = <Map<String, String>>[];
    for (final event in contract.events) {
      final transition = contract.transitions[(state, event)];
      if (transition != null && transition.allowed && transition.to != null) {
        result.add({'event': event.value});
      }
    }

    // Filter END transitions based on evolution.enabled in config.yaml
    if (state == FsmState.end) {
      final evolutionEnabled = _readEvolutionEnabled(workingDirectory);
      if (evolutionEnabled) {
        result.removeWhere((t) => t['event'] == 'pr_ready_no_evolution');
      } else {
        result.removeWhere((t) => t['event'] == 'pr_ready');
      }
    }

    return result;
  }

  bool _readEvolutionEnabled(String workingDirectory) {
    final inquiryCliRoot = _resolveInquiryCliRoot(workingDirectory);
    final configFile = File(p.join(inquiryCliRoot, '.inquiry', 'config.yaml'));
    if (!configFile.existsSync()) return false;
    try {
      final yaml = loadYaml(configFile.readAsStringSync());
      if (yaml is YamlMap) {
        final evolution = yaml['evolution'];
        if (evolution is YamlMap) {
          return evolution['enabled'] == true;
        }
      }
    } catch (_) {
      // If config is malformed, default to no evolution
    }
    return false;
  }

  String _resolveInquiryCliRoot(String workingDirectory) {
    try {
      return CycleContext.resolve(workingDirectory).inquiryCliRoot;
    } on CycleResolutionException {
      return workingDirectory;
    }
  }

  static const _stateApes = <FsmState, List<Map<String, String>>>{
    FsmState.idle: [
      {'name': 'dewey', 'status': 'RUNNING'},
    ],
    FsmState.analyze: [
      {'name': 'socrates', 'status': 'RUNNING'},
    ],
    FsmState.plan: [
      {'name': 'descartes', 'status': 'RUNNING'},
    ],
    FsmState.execute: [
      {'name': 'ada', 'status': 'RUNNING'},
    ],
    FsmState.end: [],
    FsmState.evolution: [
      {'name': 'darwin', 'status': 'RUNNING'},
    ],
  };

  List<Map<String, String>> _computeApes(FsmState state) {
    return _stateApes[state] ?? [];
  }

  OperationalContract _loadOperationalContract(FsmState state) {
    return OperationalContractLoader(
      workingDirectory: input.workingDirectory,
      assets: _assets,
    ).load(state);
  }

  /// Build `ape` info from InquiryState + APE YAML definition.
  Map<String, dynamic>? _computeApeInfo(InquiryState inquiry) {
    if (inquiry.apeName == null) return null;

    final name = inquiry.apeName!;
    final subState = inquiry.apeState;
    final result = <String, dynamic>{'name': name, 'state': subState};

    try {
      final yamlPath = _assets != null
          ? _assets.path('apes/$name.yaml')
          : p.join(input.workingDirectory, 'assets', 'apes', '$name.yaml');
      final content = File(yamlPath).readAsStringSync();
      final def = ApeDefinition.parse(content);
      if (subState != null) {
        final apeState = def.findState(subState);
        if (apeState != null) {
          result['transitions'] = apeState.transitions
              .map((t) => {'event': t.event})
              .toList();
        }
      }
    } catch (_) {
      // APE YAML not found — return partial info
    }

    return result;
  }
}
