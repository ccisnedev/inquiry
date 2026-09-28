/// `iq ape state` — reports current APE sub-state and valid transitions.
library;

import 'dart:convert';
import 'dart:io';

import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:path/path.dart' as p;

import '../../../assets.dart';
import '../ape_definition.dart';
import '../inquiry_state.dart';

// ─── Input ──────────────────────────────────────────────────────────────────

class ApeStateInput extends Input {
  final String workingDirectory;

  ApeStateInput({required this.workingDirectory});

  factory ApeStateInput.fromCliRequest(CliRequest req) {
    return ApeStateInput(workingDirectory: Directory.current.path);
  }

  /// Declares an EMPTY contract: this command accepts no option at all, so any
  /// option passed to it is refused.
  static const CliContract contract = CliContract.none;

  @override
  Map<String, dynamic> toJson() => {'workingDirectory': workingDirectory};
}

// ─── Output ─────────────────────────────────────────────────────────────────

class ApeStateOutput extends Output {
  final String? apeName;
  final String? apeState;
  final List<Map<String, String>> transitions;

  ApeStateOutput({this.apeName, this.apeState, this.transitions = const []});

  @override
  Map<String, dynamic> toJson() {
    if (apeName == null) return {'ape': null};
    return {
      'ape': {'name': apeName, 'state': apeState, 'transitions': transitions},
    };
  }

  @override
  int get exitCode => ExitCode.ok;

  @override
  String? toText() {
    if (apeName == null) return 'No active APE';
    final buf = StringBuffer();
    buf.writeln('APE: $apeName');
    buf.writeln('State: $apeState');
    if (transitions.isNotEmpty) {
      buf.writeln('Transitions:');
      for (final t in transitions) {
        buf.writeln('  --${t['event']}--> ${t['to']}');
      }
    }
    return buf.toString().trimRight();
  }

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());
}

// ─── Command ────────────────────────────────────────────────────────────────

class ApeStateCommand implements Query<ApeStateInput, ApeStateOutput> {
  @override
  final ApeStateInput input;
  final Assets? _assets;

  ApeStateCommand(this.input, {Assets? assets}) : _assets = assets;

  @override
  String? validate() => null;

  @override
  Future<ApeStateOutput> execute() async {
    final inquiryState = InquiryState.load(input.workingDirectory);

    if (inquiryState.apeName == null) {
      return ApeStateOutput();
    }

    final apeState = inquiryState.apeState;

    // If APE is _DONE, no transitions available
    if (apeState == '_DONE') {
      return ApeStateOutput(apeName: inquiryState.apeName, apeState: '_DONE');
    }

    // Load APE YAML to get valid transitions
    final yamlPath = _resolveApePath(inquiryState.apeName!);
    final yamlFile = File(yamlPath);
    if (!yamlFile.existsSync()) {
      return ApeStateOutput(apeName: inquiryState.apeName, apeState: apeState);
    }

    final definition = ApeDefinition.parse(yamlFile.readAsStringSync());
    final currentApeState = definition.findState(
      apeState ?? definition.initialState,
    );

    final transitions = <Map<String, String>>[];
    if (currentApeState != null) {
      for (final t in currentApeState.transitions) {
        transitions.add({'event': t.event, 'to': t.to});
      }
    }

    return ApeStateOutput(
      apeName: inquiryState.apeName,
      apeState: apeState ?? definition.initialState,
      transitions: transitions,
    );
  }

  String _resolveApePath(String name) {
    if (_assets != null) {
      return _assets.path('apes/$name.yaml');
    }
    return p.join(input.workingDirectory, 'assets', 'apes', '$name.yaml');
  }
}
