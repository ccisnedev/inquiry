/// `iq ape prompt <name>` — assembles a sub-agent prompt from YAML + FSM state.
///
/// Reads the YAML definition from `assets/apes/<name>.yaml`,
/// verifies the sub-agent is active in the current FSM state,
/// and returns the assembled prompt (base + optional sub-state).
library;

import 'dart:convert';
import 'dart:io';

import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:path/path.dart' as p;

import '../../../assets.dart';
import '../../../fsm_contract.dart';
import '../../../src/cycle_context.dart';
import '../../../src/git_utils.dart';
import '../ape_definition.dart';
import '../instruction_prompt_loader.dart';
import '../inquiry_state.dart';
import '../operational_contract.dart';

// ─── Input ──────────────────────────────────────────────────────────────────

class ApePromptInput extends Input {
  final String? name;
  final String? subState;
  final String workingDirectory;

  ApePromptInput({
    required this.name,
    this.subState,
    required this.workingDirectory,
  });

  static final CliContract contract = CliContract(
    options: [
      CliParam.string(
        'name',
        abbr: 'n',
        required: false,
        repeatable: false,
        defaultValue: null,
        description:
            'APE whose prompt to assemble (socrates, dewey, descartes, ada, darwin)',
      ),
      CliParam.string(
        'state',
        abbr: 's',
        required: false,
        repeatable: false,
        defaultValue: null,
        description: 'APE sub-state to assemble the prompt for',
      ),
    ],
  );

  factory ApePromptInput.fromCliRequest(CliRequest req) {
    return ApePromptInput(
      name: req.flagString('name'),
      subState: req.flagString('state'),
      workingDirectory: Directory.current.path,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
    if (name != null) 'name': name,
    if (subState != null) 'subState': subState,
    'workingDirectory': workingDirectory,
  };
}

// ─── Output ─────────────────────────────────────────────────────────────────

class ApePromptOutput extends Output {
  final String apeName;
  final String fsmState;
  final String? subState;
  final String prompt;

  ApePromptOutput({
    required this.apeName,
    required this.fsmState,
    this.subState,
    required this.prompt,
  });

  @override
  Map<String, dynamic> toJson() => {
    'ape': apeName,
    'fsm_state': fsmState,
    if (subState != null) 'sub_state': subState,
    'prompt': prompt,
  };

  @override
  int get exitCode => ExitCode.ok;

  @override
  String? toText() => prompt;
}

// ─── Command ────────────────────────────────────────────────────────────────

/// Assembles a sub-agent prompt from its YAML definition + current FSM state.
class ApePromptCommand implements Query<ApePromptInput, ApePromptOutput> {
  @override
  final ApePromptInput input;
  final Assets? _assets;

  ApePromptCommand(this.input, {Assets? assets}) : _assets = assets;

  /// Maps FSM states to their active sub-agent names.
  static const _stateApes = <FsmState, List<String>>{
    FsmState.idle: ['dewey'],
    FsmState.analyze: ['socrates'],
    FsmState.plan: ['descartes'],
    FsmState.execute: ['ada'],
    FsmState.end: [],
    FsmState.evolution: ['darwin'],
  };

  @override
  String? validate() => null;

  late final CycleContext? _cycleContext = _tryResolveCycleContext();

  @override
  Future<ApePromptOutput> execute() async {
    if (input.name == null || input.name!.trim().isEmpty) {
      throw CommandException(
        id: 'missing-name',
        message:
            'Missing required flag --name. Usage: iq ape prompt --name <name>',
        exitCode: ExitCode.validationFailed,
      );
    }
    final inquiry = InquiryState.load(input.workingDirectory);
    final currentState = FsmState.fromValue(inquiry.state.trim().toUpperCase());

    // Verify the APE exists
    final yamlPath = _resolveApePath(input.name!);
    final yamlFile = File(yamlPath);
    if (!yamlFile.existsSync()) {
      throw CommandException(
        id: 'ape-not-found',
        message: 'No definition found for "${input.name!}" at $yamlPath',
        exitCode: ExitCode.notFound,
      );
    }

    // Verify the APE is active in the current FSM state
    final activeApes = _stateApes[currentState] ?? [];
    if (!activeApes.contains(input.name!)) {
      throw CommandException(
        id: 'ape-not-active',
        message:
            '"${input.name!}" is not active in state '
            '${currentState.value}. Active APEs: ${activeApes.join(', ')}',
        exitCode: ExitCode.conflict,
      );
    }

    // Resolve sub-state: explicit flag > state.yaml > null
    final resolvedSubState = input.subState ?? inquiry.apeState;

    final operationalContract = OperationalContractLoader(
      workingDirectory: input.workingDirectory,
      assets: _assets,
    ).load(currentState);
    final transitionInstructions = _resolveTransitionInstructions(inquiry);
    final context = _resolveContext(
      input.name!,
      resolvedSubState,
      inquiry: inquiry,
      operationalContract: operationalContract,
    );

    // Parse and assemble
    final assemblyStartedAt = DateTime.now().toUtc();
    final definition = ApeDefinition.parse(yamlFile.readAsStringSync());
    final prompt = definition.assemblePrompt(
      stateName: resolvedSubState,
      transitionInstructions: transitionInstructions,
      operationalContract: operationalContract.render(),
      context: context,
    );
    _recordModelActivityTrace(
      currentState: currentState,
      inquiry: inquiry,
      apeName: input.name!,
      subState: resolvedSubState,
      prompt: prompt,
      assemblyStartedAt: assemblyStartedAt,
      assemblyEndedAt: DateTime.now().toUtc(),
    );

    return ApePromptOutput(
      apeName: input.name!,
      fsmState: currentState.value,
      subState: resolvedSubState,
      prompt: prompt,
    );
  }

  String? _resolveTransitionInstructions(InquiryState inquiry) {
    final promptFragmentId = inquiry.promptFragmentId;
    if (promptFragmentId == null || promptFragmentId.trim().isEmpty) {
      return null;
    }

    final contractPath = _assets != null
        ? _assets.path('fsm/transition_contract.yaml')
        : p.join(
            _resolvedProjectRoot,
            'assets',
            'fsm',
            'transition_contract.yaml',
          );
    final contract = parseFsmContract(File(contractPath).readAsStringSync());
    final fragment = contract.promptFragments[promptFragmentId];
    if (fragment == null) {
      throw CommandException(
        id: 'prompt-fragment-not-found',
        message: 'No prompt fragment found for "$promptFragmentId"',
        exitCode: ExitCode.notFound,
      );
    }
    if (fragment.instructions.isEmpty) {
      return null;
    }

    final assets = _assets ?? Assets(root: input.workingDirectory);
    final loader = InstructionPromptLoader(assets: assets);
    return loader.loadMany(fragment.instructions);
  }

  /// Resolves dynamic context paths per APE and FSM state.
  Map<String, String>? _resolveContext(
    String apeName,
    String? subState, {
    required InquiryState inquiry,
    required OperationalContract operationalContract,
  }) {
    final context = <String, String>{};

    final stateOwnedContext = operationalContract.inquiryContextFor(
      apeName: apeName,
      subState: subState,
    );
    if (stateOwnedContext != null) {
      context.addAll(stateOwnedContext);
    }

    final runtimeContext = _resolveRuntimeContext(apeName, inquiry);
    if (runtimeContext != null) {
      context.addAll(runtimeContext);
    }

    return context.isEmpty ? null : context;
  }

  Map<String, String>? _resolveRuntimeContext(
    String apeName,
    InquiryState inquiry,
  ) {
    final cycleContext = _cycleContext;
    final branch = cycleContext?.branch;
    if (cycleContext == null || branch == null) return null;

    final cleanroomRoot = 'cleanrooms/$branch/';
    final analyzeDir = 'cleanrooms/$branch/analyze/';
    final runTraceFile = '${cleanroomRoot}run_trace.yaml';
    const metricsFile = '.inquiry/metrics.yaml';
    const failureTaxonomySurface = 'docs/spec/eval-model.md';
    const failureClassificationMode =
        'classify repeated failures as model, host, inquiry_harness, or mixed';
    final taskId = (inquiry.issue != null && inquiry.issue!.trim().isNotEmpty)
        ? inquiry.issue!.trim()
        : branch;

    final baseContext = <String, String>{
      'project_root': cycleContext.projectRoot,
      'task_id': taskId,
    };

    switch (apeName) {
      case 'socrates':
        return {
          ...baseContext,
          ..._contextPolicy(
            contextPolicy: 'progressive-disclosure',
            authorityMode: 'build-authoritative-analysis',
            upfrontContext: [
              '${cleanroomRoot}issue.md',
              '${analyzeDir}index.md',
            ],
            retrievalContext: [
              '${analyzeDir}index.md',
              '${analyzeDir}confirmations.md',
              cycleContext.projectRoot,
            ],
            deferredContext: const [
              'broad repository rereads not justified by the active uncertainty',
            ],
            authoritativeHandoff: '${analyzeDir}diagnosis.md',
            authorityRule:
                'diagnosis.md becomes the authoritative handoff to PLAN once written',
          ),
          'retrieval_trigger_rule':
              'widen retrieval only when the bounded analysis corpus leaves a named uncertainty unresolved',
          'reread_avoidance_rule':
              'do not restart repository-wide discovery when issue.md, index.md, and confirmations.md already bound the active uncertainty',
          ..._sensorContext(
            sensorPolicy: 'minimum-phase-stack',
            minimumSensorStack: const [
              'runtime',
              'pre_transition',
              'inferential_optional',
            ],
            blockingSensorStack: const ['runtime', 'pre_transition'],
            advisorySensorStack: const ['inferential_optional'],
            sensorGate: 'handoff-to-plan',
            sensorAuthorityRule:
                'analysis corpus and diagnosis handoff must be complete enough before PLAN handoff can proceed',
          ),
          ..._observabilityContext(
            observabilityPolicy: 'minimum-phase-trace',
            resultMetricsSurface: metricsFile,
            executionTraceSurface: runTraceFile,
            traceTargets: const [
              'transition',
              'sensor_run',
              'block',
              'retry',
              'phase_timing',
              'tool_activity',
            ],
            failureTaxonomySurface: failureTaxonomySurface,
            observabilityAuthorityRule:
                'execution_trace_surface and bounded artifacts outrank retrospective summaries when diagnosing ANALYZE behavior',
          ),
          ..._evalContext(
            evalPolicy: 'harness-minimum',
            evalTargets: const ['evidence_discipline_failure'],
            failureClassificationMode: failureClassificationMode,
            graderStack: const [
              'structure_grader',
              'artifact_consistency_grader',
              'human_audit_grader',
            ],
            evalAuthorityRule:
                'artifact and trace evidence outrank narrative retrospection when evaluating ANALYZE quality',
          ),
          'evidence_policy': 'evidence-first',
          'evidence_acquisition_order': _yamlList([
            'repo',
            'cycle_artifacts',
            'docs',
            'tests',
            'runtime_evidence',
            'web_research',
            'user_questions',
          ]),
          'question_escalation_rule':
              'ask the user only after repo, cycle artifact, docs, tests, runtime evidence, and targeted web research leave a material uncertainty',
          'diagnosis_requirements': _yamlList([
            'record concrete observed evidence before handoff',
            'distinguish observed evidence from hypotheses',
            'record constraints explicitly',
            'record open questions only when evidence cannot close them',
          ]),
          'input_artifacts': _yamlList([
            '${cleanroomRoot}issue.md',
            '${analyzeDir}index.md',
          ]),
          'expected_outputs': _yamlList([
            '${analyzeDir}confirmations.md',
            '${analyzeDir}diagnosis.md',
          ]),
          'editable_surfaces': _yamlList([analyzeDir]),
          'read_only_surfaces': _yamlList(['${cleanroomRoot}issue.md']),
          'validation_commands': _yamlList(const []),
          'done_criteria': _yamlList([
            '${analyzeDir}diagnosis.md is written',
            '${analyzeDir}confirmations.md captures the bounded analysis corpus',
          ]),
          'output_dir': analyzeDir,
          'index_file': '${analyzeDir}index.md',
          'confirmations_doc': '${analyzeDir}confirmations.md',
          'doc_protocol': 'doc-write',
        };
      case 'descartes':
        return {
          ...baseContext,
          ..._contextPolicy(
            contextPolicy: 'authoritative-handoff',
            authorityMode: 'trust-diagnosis-first',
            upfrontContext: ['${analyzeDir}diagnosis.md'],
            retrievalContext: [
              '${analyzeDir}index.md',
              cycleContext.projectRoot,
            ],
            deferredContext: const [
              'reconstructing ANALYZE from broad rereads when diagnosis.md is already authoritative',
            ],
            authoritativeHandoff: '${analyzeDir}diagnosis.md',
            authorityRule:
                'trust diagnosis.md as the planning baseline unless a concrete gap requires targeted retrieval',
          ),
          'retrieval_trigger_rule':
              'retrieve adjacent repo evidence only when diagnosis.md leaves a concrete gap that would change plan structure, scope, or verification',
          'reread_avoidance_rule':
              'do not reconstruct ANALYZE from broad rereads when diagnosis.md already answers the planning question',
          ..._sensorContext(
            sensorPolicy: 'minimum-phase-stack',
            minimumSensorStack: const [
              'runtime',
              'pre_transition',
              'inferential_optional',
            ],
            blockingSensorStack: const ['runtime', 'pre_transition'],
            advisorySensorStack: const ['inferential_optional'],
            sensorGate: 'handoff-to-execute',
            sensorAuthorityRule:
                'plan.md and issue-linked runtime context must be coherent before EXECUTE handoff',
          ),
          ..._observabilityContext(
            observabilityPolicy: 'minimum-phase-trace',
            resultMetricsSurface: metricsFile,
            executionTraceSurface: runTraceFile,
            traceTargets: const [
              'transition',
              'sensor_run',
              'block',
              'retry',
              'phase_timing',
              'tool_activity',
            ],
            failureTaxonomySurface: failureTaxonomySurface,
            observabilityAuthorityRule:
                'execution_trace_surface and authoritative handoff artifacts outrank retrospective summaries when diagnosing PLAN behavior',
          ),
          ..._evalContext(
            evalPolicy: 'harness-minimum',
            evalTargets: const ['handoff_authority_failure'],
            failureClassificationMode: failureClassificationMode,
            graderStack: const [
              'structure_grader',
              'artifact_consistency_grader',
              'human_audit_grader',
            ],
            evalAuthorityRule:
                'authoritative artifacts outrank narrative retrospection when evaluating planning handoffs',
          ),
          'input_artifacts': _yamlList(['${analyzeDir}diagnosis.md']),
          'expected_outputs': _yamlList(['${cleanroomRoot}plan.md']),
          'editable_surfaces': _yamlList(['${cleanroomRoot}plan.md']),
          'read_only_surfaces': _yamlList(['${analyzeDir}diagnosis.md']),
          'validation_commands': _yamlList(const []),
          'done_criteria': _yamlList([
            '${cleanroomRoot}plan.md defines ordered phases',
            '${cleanroomRoot}plan.md includes verification criteria for each phase',
          ]),
          'analysis_input': '${analyzeDir}diagnosis.md',
          'output_dir': cleanroomRoot,
          'plan_file': '${cleanroomRoot}plan.md',
          'doc_protocol': 'doc-read',
        };
      case 'ada':
        return {
          ...baseContext,
          ..._contextPolicy(
            contextPolicy: 'authoritative-handoff',
            authorityMode: 'trust-plan-first',
            upfrontContext: ['${cleanroomRoot}plan.md'],
            retrievalContext: [cycleContext.projectRoot, cleanroomRoot],
            deferredContext: const [
              're-reading broad analysis artifacts when plan.md already defines the bounded execution contract',
            ],
            authoritativeHandoff: '${cleanroomRoot}plan.md',
            authorityRule:
                'trust plan.md as the execution baseline unless implementation hits a concrete ambiguity that requires targeted retrieval',
          ),
          'retrieval_trigger_rule':
              'retrieve targeted code or cycle-local evidence only when plan.md leaves a concrete implementation or verification ambiguity',
          'reread_avoidance_rule':
              'do not re-read broad analysis artifacts when plan.md already defines the bounded execution contract',
          ..._sensorContext(
            sensorPolicy: 'minimum-phase-stack',
            minimumSensorStack: const [
              'local_fast',
              'pre_transition',
              'pre_pr',
              'runtime',
            ],
            blockingSensorStack: const [
              'local_fast',
              'pre_transition',
              'runtime',
            ],
            advisorySensorStack: const ['inferential_optional'],
            sensorGate: 'handoff-to-end',
            sensorAuthorityRule:
                'pre_pr evidence must be complete before END handoff even when phase-local checks are green',
          ),
          ..._observabilityContext(
            observabilityPolicy: 'minimum-phase-trace',
            resultMetricsSurface: metricsFile,
            executionTraceSurface: runTraceFile,
            traceTargets: const [
              'transition',
              'sensor_run',
              'block',
              'retry',
              'phase_timing',
              'tool_activity',
            ],
            failureTaxonomySurface: failureTaxonomySurface,
            observabilityAuthorityRule:
                'execution_trace_surface and pre_pr_inspection_report outrank retrospective summaries when explaining EXECUTE cost or blocking',
          ),
          ..._evalContext(
            evalPolicy: 'harness-minimum',
            evalTargets: const ['sensor_gate_failure', 'observability_failure'],
            failureClassificationMode: failureClassificationMode,
            graderStack: const [
              'structure_grader',
              'trace_grader',
              'artifact_consistency_grader',
            ],
            evalAuthorityRule:
                'trace and gate artifacts outrank narrative retrospection when evaluating EXECUTE closure behavior',
          ),
          'release_gate':
              'propose semver bump and get explicit user approval before END handoff',
          'input_artifacts': _yamlList(['${cleanroomRoot}plan.md']),
          'expected_outputs': _yamlList([
            cycleContext.projectRoot,
            cleanroomRoot,
          ]),
          'editable_surfaces': _yamlList([
            cycleContext.projectRoot,
            cleanroomRoot,
          ]),
          'read_only_surfaces': _yamlList(['${cleanroomRoot}plan.md']),
          'validation_commands': _yamlList(const []),
          'done_criteria': _yamlList([
            'implementation remains bounded by ${cleanroomRoot}plan.md',
            'changed slices satisfy the active coding manifesto before phase completion',
            'semver bump proposal is explicit and user-approved before END handoff',
            'required validations complete before END',
          ]),
          'pre_pr_inspection_report': '${cleanroomRoot}pre_pr_inspection.md',
          'plan_file': '${cleanroomRoot}plan.md',
          'output_dir': cleanroomRoot,
          'doc_protocol': 'doc-read',
        };
      case 'darwin':
        return {
          ...baseContext,
          ..._observabilityContext(
            observabilityPolicy: 'evolution-audit',
            resultMetricsSurface: metricsFile,
            executionTraceSurface: runTraceFile,
            traceTargets: const [
              'transition',
              'sensor_run',
              'block',
              'retry',
              'phase_timing',
            ],
            failureTaxonomySurface: failureTaxonomySurface,
            observabilityAuthorityRule:
                'execution traces and result metrics outrank retrospective summaries when evaluating recurring harness failures',
          ),
          ..._evalContext(
            evalPolicy: 'harness-evolution-minimum',
            evalTargets: const [
              'task_contract_failure',
              'evidence_discipline_failure',
              'handoff_authority_failure',
              'sensor_gate_failure',
              'observability_failure',
            ],
            failureClassificationMode: failureClassificationMode,
            graderStack: const [
              'structure_grader',
              'trace_grader',
              'artifact_consistency_grader',
              'human_audit_grader',
            ],
            evalAuthorityRule:
                'trace and artifact graders outrank narrative retrospection when classifying repeated harness failures',
          ),
          'input_artifacts': _yamlList([
            '${analyzeDir}diagnosis.md',
            '${cleanroomRoot}plan.md',
            '${cleanroomRoot}retrospective.md',
            '${cleanroomRoot}mutations.md',
            metricsFile,
            '.inquiry/metrics_snapshot.yaml',
          ]),
          'expected_outputs': _yamlList([cleanroomRoot]),
          'editable_surfaces': _yamlList([
            '${cleanroomRoot}mutations.md',
            cleanroomRoot,
          ]),
          'read_only_surfaces': _yamlList([
            '${analyzeDir}diagnosis.md',
            '${cleanroomRoot}plan.md',
            '$cleanroomRoot.iq.state.yaml',
            metricsFile,
            '.inquiry/metrics_snapshot.yaml',
          ]),
          'validation_commands': _yamlList(const []),
          'done_criteria': _yamlList([
            'evolution findings stay grounded in cycle artifacts',
            'proposed mutations are traceable to observed evidence',
          ]),
          'analyze_dir': analyzeDir,
          'diagnosis_file': '${analyzeDir}diagnosis.md',
          'plan_file': '${cleanroomRoot}plan.md',
          'retrospective_file': '${cleanroomRoot}retrospective.md',
          'mutations_file': '${cleanroomRoot}mutations.md',
          'state_file': '$cleanroomRoot.iq.state.yaml',
          'metrics_snapshot_file': '.inquiry/metrics_snapshot.yaml',
          'metrics_file': metricsFile,
          'output_dir': cleanroomRoot,
        };
      default:
        return null;
    }
  }

  CycleContext? _tryResolveCycleContext() {
    try {
      return CycleContext.resolve(input.workingDirectory);
    } on CycleResolutionException {
      return null;
    }
  }

  void _recordModelActivityTrace({
    required FsmState currentState,
    required InquiryState inquiry,
    required String apeName,
    required String? subState,
    required String prompt,
    required DateTime assemblyStartedAt,
    required DateTime assemblyEndedAt,
  }) {
    if (currentState == FsmState.idle) return;

    final tracePath = _runTracePath();
    final branch = _cycleContext?.branch;
    if (tracePath == null || branch == null) return;

    final promptCharacters = prompt.runes.length;
    final promptLines = prompt.isEmpty ? 0 : '\n'.allMatches(prompt).length + 1;
    final promptBytes = utf8.encode(prompt).length;
    final estimatedInputTokens = promptCharacters == 0
        ? 0
        : ((promptCharacters + 3) ~/ 4);
    final assemblyDuration = assemblyEndedAt.difference(assemblyStartedAt);

    final lines = <String>[
      '    event_class: model_activity',
      '    phase: ${currentState.value}',
      '    ape_name: $apeName',
      '    model_surface: prompt_input',
      '    prompt_characters: $promptCharacters',
      '    prompt_lines: $promptLines',
      '    prompt_utf8_bytes: $promptBytes',
      '    estimated_input_tokens: $estimatedInputTokens',
      '    token_estimate_basis: chars_div_4_ceil',
      '    assembly_duration_seconds: ${assemblyDuration.inMilliseconds / 1000}',
    ];

    if (subState != null && subState.trim().isNotEmpty) {
      lines.add('    sub_state: $subState');
    }
    if (inquiry.promptFragmentId != null &&
        inquiry.promptFragmentId!.trim().isNotEmpty) {
      lines.add('    prompt_fragment_id: ${inquiry.promptFragmentId!}');
    }

    _appendRunTraceEvent(lines, issue: inquiry.issue);
  }

  void _appendRunTraceEvent(List<String> lines, {String? issue}) {
    final tracePath = _runTracePath();
    final branch = _cycleContext?.branch;
    if (tracePath == null || branch == null) return;

    final file = File(tracePath);
    file.parent.createSync(recursive: true);

    final taskId = (issue != null && issue.trim().isNotEmpty)
        ? issue.trim()
        : branch;
    final buffer = StringBuffer()
      ..writeln(
        '  - recorded_at: "${DateTime.now().toUtc().toIso8601String()}"',
      )
      ..writeln('    task_id: ${_yamlQuoted(taskId)}')
      ..writeln('    branch: $branch');

    for (final line in lines) {
      buffer.writeln(line);
    }

    if (file.existsSync()) {
      file.writeAsStringSync(buffer.toString(), mode: FileMode.append);
    } else {
      file.writeAsStringSync('events:\n${buffer.toString()}');
    }
  }

  String? _runTracePath() {
    final cleanroomRoot = _cycleContext?.inquiryRoot;
    if (cleanroomRoot == null) return null;
    return p.join(cleanroomRoot, 'run_trace.yaml');
  }

  String _yamlQuoted(String value) {
    return '"${value.replaceAll(r'\\', r'\\\\').replaceAll('"', '\\"')}"';
  }

  String get _resolvedProjectRoot =>
      _cycleContext?.projectRoot ??
      getProjectRoot(input.workingDirectory) ??
      input.workingDirectory;

  String _yamlList(List<String> values) {
    if (values.isEmpty) return '[]';
    return '[${values.map(_yamlScalar).join(', ')}]';
  }

  Map<String, String> _contextPolicy({
    required String contextPolicy,
    required String authorityMode,
    required List<String> upfrontContext,
    required List<String> retrievalContext,
    required List<String> deferredContext,
    required String authoritativeHandoff,
    required String authorityRule,
  }) {
    return {
      'context_policy': contextPolicy,
      'authority_mode': authorityMode,
      'upfront_context': _yamlList(upfrontContext),
      'retrieval_context': _yamlList(retrievalContext),
      'deferred_context': _yamlList(deferredContext),
      'authoritative_handoff': authoritativeHandoff,
      'authority_rule': authorityRule,
    };
  }

  Map<String, String> _sensorContext({
    required String sensorPolicy,
    required List<String> minimumSensorStack,
    required List<String> blockingSensorStack,
    required List<String> advisorySensorStack,
    required String sensorGate,
    required String sensorAuthorityRule,
  }) {
    return {
      'sensor_policy': sensorPolicy,
      'minimum_sensor_stack': _yamlList(minimumSensorStack),
      'blocking_sensor_stack': _yamlList(blockingSensorStack),
      'advisory_sensor_stack': _yamlList(advisorySensorStack),
      'sensor_gate': sensorGate,
      'sensor_authority_rule': sensorAuthorityRule,
    };
  }

  Map<String, String> _observabilityContext({
    required String observabilityPolicy,
    required String resultMetricsSurface,
    required String executionTraceSurface,
    required List<String> traceTargets,
    required String failureTaxonomySurface,
    required String observabilityAuthorityRule,
  }) {
    return {
      'observability_policy': observabilityPolicy,
      'result_metrics_surface': resultMetricsSurface,
      'execution_trace_surface': executionTraceSurface,
      'trace_targets': _yamlList(traceTargets),
      'failure_taxonomy_surface': failureTaxonomySurface,
      'observability_authority_rule': observabilityAuthorityRule,
    };
  }

  Map<String, String> _evalContext({
    required String evalPolicy,
    required List<String> evalTargets,
    required String failureClassificationMode,
    required List<String> graderStack,
    required String evalAuthorityRule,
  }) {
    return {
      'eval_policy': evalPolicy,
      'eval_targets': _yamlList(evalTargets),
      'failure_classification_mode': failureClassificationMode,
      'grader_stack': _yamlList(graderStack),
      'eval_authority_rule': evalAuthorityRule,
    };
  }

  String _yamlScalar(String value) {
    return "'${value.replaceAll("'", "''")}'";
  }

  String _resolveApePath(String name) {
    if (_assets != null) {
      return _assets.path('apes/$name.yaml');
    }
    return p.join(_resolvedProjectRoot, 'assets', 'apes', '$name.yaml');
  }
}
