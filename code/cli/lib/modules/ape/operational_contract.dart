library;

import 'dart:io';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../../assets.dart';
import '../../fsm_contract.dart';

class OperationalContract {
  final FsmState state;
  final String instructions;
  final List<String> constraints;
  final List<String> allowedActions;
  final List<String> requiredArtifacts;
  final Map<String, dynamic> interaction;
  final Map<String, Map<String, Map<String, String>>> inquiryContext;

  const OperationalContract({
    required this.state,
    required this.instructions,
    required this.constraints,
    required this.allowedActions,
    this.requiredArtifacts = const [],
    this.interaction = const {},
    this.inquiryContext = const {},
  });

  Map<String, dynamic> toJson() => {
    'state': state.value,
    'instructions': instructions,
    'constraints': constraints,
    'allowed_actions': allowedActions,
    if (requiredArtifacts.isNotEmpty) 'required_artifacts': requiredArtifacts,
    if (interaction.isNotEmpty) 'interaction': interaction,
    if (inquiryContext.isNotEmpty) 'inquiry_context': inquiryContext,
  };

  Map<String, String>? inquiryContextFor({
    required String apeName,
    String? subState,
  }) {
    if (subState == null) return null;

    final apeContext = inquiryContext[apeName];
    if (apeContext == null) return null;

    final subStateContext = apeContext[subState];
    if (subStateContext == null || subStateContext.isEmpty) {
      return null;
    }

    return subStateContext;
  }

  String render() {
    final buffer = StringBuffer()
      ..writeln('## Phase-Owned Operational Contract')
      ..writeln('State: ${state.value}')
      ..writeln()
      ..writeln('Mission:')
      ..writeln(instructions.trim());

    if (constraints.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Constraints:');
      for (final constraint in constraints) {
        buffer.writeln('- $constraint');
      }
    }

    if (allowedActions.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Allowed actions:');
      for (final action in allowedActions) {
        buffer.writeln('- $action');
      }
    }

    return buffer.toString().trimRight();
  }
}

class OperationalContractLoader {
  final String workingDirectory;
  final Assets? assets;

  const OperationalContractLoader({
    required this.workingDirectory,
    this.assets,
  });

  OperationalContract load(FsmState state) {
    final stateName = state.value.toLowerCase();
    final yamlPath = assets != null
        ? assets!.path('fsm/states/$stateName.yaml')
        : p.join(
            workingDirectory,
            'assets',
            'fsm',
            'states',
            '$stateName.yaml',
          );

    final yaml = _readYamlMap(yamlPath, stateName);
    final instructions = _readStringField(
      yaml,
      fieldName: 'instructions',
      stateName: stateName,
    );
    final constraints = _readStringListField(
      yaml,
      fieldName: 'constraints',
      stateName: stateName,
    );
    final allowedActions = _readStringListField(
      yaml,
      fieldName: 'allowed_actions',
      stateName: stateName,
    );
    final requiredArtifacts = _readOptionalStringListField(
      yaml,
      fieldName: 'required_artifacts',
      stateName: stateName,
    );
    final interaction = _readInteractionField(yaml, stateName: stateName);
    final inquiryContext = _readInquiryContextField(yaml, stateName: stateName);

    return OperationalContract(
      state: state,
      instructions: instructions.trim(),
      constraints: constraints,
      allowedActions: allowedActions,
      requiredArtifacts: requiredArtifacts,
      interaction: interaction,
      inquiryContext: inquiryContext,
    );
  }

  YamlMap _readYamlMap(String yamlPath, String stateName) {
    try {
      final yaml = loadYaml(File(yamlPath).readAsStringSync());
      if (yaml is YamlMap) {
        return yaml;
      }
      throw _malformedStateYaml(stateName, 'root mapping');
    } on PathNotFoundException {
      throw _missingStateYaml(stateName);
    } on FileSystemException {
      throw _missingStateYaml(stateName);
    }
  }

  String _readStringField(
    YamlMap yaml, {
    required String fieldName,
    required String stateName,
  }) {
    final value = yaml[fieldName];
    if (value is String && value.trim().isNotEmpty) {
      return value;
    }
    throw _malformedStateYaml(stateName, fieldName);
  }

  List<String> _readStringListField(
    YamlMap yaml, {
    required String fieldName,
    required String stateName,
  }) {
    final value = yaml[fieldName];
    if (value is YamlList) {
      return value.cast<String>().toList(growable: false);
    }
    throw _malformedStateYaml(stateName, fieldName);
  }

  List<String> _readOptionalStringListField(
    YamlMap yaml, {
    required String fieldName,
    required String stateName,
  }) {
    final value = yaml[fieldName];
    if (value == null) {
      return const [];
    }
    if (value is YamlList) {
      return value.cast<String>().toList(growable: false);
    }
    throw _malformedStateYaml(stateName, fieldName);
  }

  Map<String, dynamic> _readInteractionField(
    YamlMap yaml, {
    required String stateName,
  }) {
    final value = yaml['interaction'];
    if (value == null) {
      return const {};
    }
    if (value is! YamlMap) {
      throw _malformedStateYaml(stateName, 'interaction');
    }

    final interaction = <String, dynamic>{};
    for (final entry in value.entries) {
      final key = entry.key;
      final fieldValue = entry.value;
      if (key is! String) {
        throw _malformedStateYaml(stateName, 'interaction');
      }
      if (fieldValue is String || fieldValue is bool || fieldValue is int) {
        interaction[key] = fieldValue;
        continue;
      }
      throw _malformedStateYaml(stateName, 'interaction');
    }

    return interaction;
  }

  Map<String, Map<String, Map<String, String>>> _readInquiryContextField(
    YamlMap yaml, {
    required String stateName,
  }) {
    final value = yaml['inquiry_context'];
    if (value == null) {
      return const {};
    }
    if (value is! YamlMap) {
      throw _malformedStateYaml(stateName, 'inquiry_context');
    }

    final inquiryContext = <String, Map<String, Map<String, String>>>{};
    for (final apeEntry in value.entries) {
      final apeName = apeEntry.key;
      final apeValue = apeEntry.value;
      if (apeName is! String || apeValue is! YamlMap) {
        throw _malformedStateYaml(stateName, 'inquiry_context');
      }

      final subStateContext = <String, Map<String, String>>{};
      for (final subStateEntry in apeValue.entries) {
        final subStateName = subStateEntry.key;
        final subStateValue = subStateEntry.value;
        if (subStateName is! String || subStateValue is! YamlMap) {
          throw _malformedStateYaml(stateName, 'inquiry_context');
        }

        final contextFields = <String, String>{};
        for (final contextEntry in subStateValue.entries) {
          final contextKey = contextEntry.key;
          final contextValue = contextEntry.value;
          if (contextKey is! String ||
              contextValue is! String ||
              contextValue.trim().isEmpty) {
            throw _malformedStateYaml(stateName, 'inquiry_context');
          }
          contextFields[contextKey] = contextValue;
        }

        subStateContext[subStateName] = contextFields;
      }

      inquiryContext[apeName] = subStateContext;
    }

    return inquiryContext;
  }

  CommandException _missingStateYaml(String stateName) {
    return CommandException(
      id: 'missing-state-yaml',
      message:
          "State instructions missing for '$stateName'. Run 'iq doctor --fix' to repair.",
      exitCode: ExitCode.genericError,
    );
  }

  CommandException _malformedStateYaml(String stateName, String fieldName) {
    return CommandException(
      id: 'malformed-state-yaml',
      message:
          "State file for '$stateName' is missing '$fieldName' field. Run 'iq doctor --fix' to repair.",
      exitCode: ExitCode.genericError,
    );
  }
}
