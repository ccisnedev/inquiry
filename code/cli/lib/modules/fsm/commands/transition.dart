library;

import 'dart:io';

import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:path/path.dart' as p;

import '../../../assets.dart';
import '../../../fsm_contract.dart';
import '../../../src/git_utils.dart';
import '../../ape/instruction_prompt_loader.dart';
import '../../ape/inquiry_state.dart';
import '../effect_executor.dart';
import '../pre_pr_inspection_runner.dart';

typedef BranchProvider = Future<String> Function(String workingDirectory);
typedef GitCommandRunner =
    Future<ProcessResult> Function(
      String workingDirectory,
      List<String> arguments,
    );

const _requiredInspectionPasses = <String>[
  'Consistency',
  'Completeness',
  'Traceability',
];

final RegExp _inspectionCheckPattern = RegExp(
  r'^-\s+(PASS|FAIL|WARN):\s+(.+)$',
  caseSensitive: false,
);

final RegExp _fileLineCitationPattern = RegExp(
  r'(^|[\s(])([A-Za-z0-9._/-]+):(\d+)(?=$|[\s)])',
);

final Map<String, RegExp> _diagnosisSectionPatterns = <String, RegExp>{
  'Evidence': RegExp(
    r'^##?\s+(Evidence|Evidencia)\b',
    caseSensitive: false,
    multiLine: true,
  ),
  'Hypotheses': RegExp(
    r'^##?\s+(Hypotheses|Hypothesis|Hipotesis|Hipótesis)\b',
    caseSensitive: false,
    multiLine: true,
  ),
  'Constraints': RegExp(
    r'^##?\s+(Constraints|Restricciones)\b',
    caseSensitive: false,
    multiLine: true,
  ),
  'Open Questions': RegExp(
    r'^##?\s+(Open Questions|Open Question|Preguntas Abiertas)\b',
    caseSensitive: false,
    multiLine: true,
  ),
};

const _diagnosisEvidenceBootstrapPlaceholder =
    'record observed repo, artifact, test, runtime, or research evidence here.';

class _BoundaryCommitSpec {
  final String label;
  final String path;
  final String message;

  const _BoundaryCommitSpec({
    required this.label,
    required this.path,
    required this.message,
  });
}

class _BoundaryCommitResult {
  final List<String> operationsExecuted;
  final String? errorMessage;

  const _BoundaryCommitResult.success({this.operationsExecuted = const []})
    : errorMessage = null;

  const _BoundaryCommitResult.failure(this.errorMessage)
    : operationsExecuted = const [];
}

class _PrePrInspectionCheck {
  final String status;
  final String detail;

  const _PrePrInspectionCheck({required this.status, required this.detail});

  bool get requiresFileLineCitation => status == 'FAIL';

  bool get hasFileLineCitation => _fileLineCitationPattern.hasMatch(detail);
}

class _PrePrInspectionReport {
  final bool exists;
  final String? verdict;
  final Map<String, List<_PrePrInspectionCheck>> checksByPass;

  const _PrePrInspectionReport({
    required this.exists,
    required this.verdict,
    required this.checksByPass,
  });

  bool get hasRequiredPassStructure => _requiredInspectionPasses.every(
    (pass) =>
        (checksByPass[pass] ?? const <_PrePrInspectionCheck>[]).isNotEmpty,
  );

  bool get hasFailChecks => checksByPass.values
      .expand((checks) => checks)
      .any((check) => check.status == 'FAIL');

  bool get hasMissingRequiredCitations => checksByPass.values
      .expand((checks) => checks)
      .any(
        (check) => check.requiresFileLineCitation && !check.hasFileLineCitation,
      );
}

class StateTransitionInput extends Input {
  final String? currentState;
  final String? event;
  final String? issue;
  final String workingDirectory;

  StateTransitionInput({
    required this.currentState,
    required this.event,
    this.issue,
    required this.workingDirectory,
  });

  static final CliContract contract = CliContract(
    options: [
      CliParam.enumeration(
        'event',
        abbr: 'e',
        required: true,
        repeatable: false,
        values: [for (final e in FsmEvent.values) e.value],
        defaultValue: null,
        description: 'The transition to execute',
      ),
      CliParam.enumeration(
        'state',
        abbr: 's',
        required: false,
        repeatable: false,
        values: [for (final s in FsmState.values) s.value],
        defaultValue: null,
        description:
            'State to transition from; read from the cycle when omitted',
      ),
      CliParam.string(
        'issue',
        abbr: 'i',
        required: false,
        repeatable: false,
        defaultValue: null,
        description: 'Issue the cycle is opened for (start_analyze)',
      ),
    ],
  );

  factory StateTransitionInput.fromCliRequest(CliRequest req) {
    return StateTransitionInput(
      currentState: req.flagString('state'),
      event: req.flagString('event'),
      issue: req.flagString('issue'),
      workingDirectory: Directory.current.path,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
    'currentState': currentState,
    'event': event,
    'issue': issue,
    'workingDirectory': workingDirectory,
  };
}

class StateTransitionOutput extends Output {
  final bool allowed;
  final String currentState;
  final String event;
  final String? nextState;
  final List<String> operationsExecuted;
  final String? promptFragmentId;
  final String? requiredRole;
  final List<String>? requiredInstructions;
  final String? instructionSummary;
  final String message;
  final int code;

  StateTransitionOutput({
    required this.allowed,
    required this.currentState,
    required this.event,
    required this.nextState,
    required this.operationsExecuted,
    required this.promptFragmentId,
    required this.requiredRole,
    required this.requiredInstructions,
    this.instructionSummary,
    required this.message,
    required this.code,
  });

  @override
  Map<String, dynamic> toJson() => {
    'allowed': allowed,
    'current_state': currentState,
    'event': event,
    'next_state': nextState,
    'operations_executed': operationsExecuted,
    'prompt_fragment_id': promptFragmentId,
    'required_role': requiredRole,
    'required_instructions': requiredInstructions,
    'instruction_summary': instructionSummary,
    'message': message,
  };

  @override
  int get exitCode => code;

  @override
  String? toText() {
    // A gate/precondition block: tell the scheduler to repair the artifact and
    // retry, NOT to re-fire the same event (which would just fail again).
    final gateHint = (!allowed && code == ExitCode.validationFailed)
        ? '\n\n→ Precondition not met. Do NOT re-run "$event" unchanged — that is a '
              'blind retry and will keep failing. Fix what the error reports above; '
              'for an artifact gate, re-dispatch the operator to repair the `.md` '
              '(read it, fix it, write it back), then retry the transition.'
        : '';

    final instructions = requiredInstructions;
    if (instructions == null || instructions.isEmpty) {
      return '$message$gateHint';
    }

    final summary = instructionSummary?.trim();
    final buffer = StringBuffer()..writeln(message);
    buffer.writeln(
      requiredRole != null
          ? 'required_role: $requiredRole'
          : 'required_role: null',
    );
    buffer.writeln('required_instructions: ${instructions.join(', ')}');
    buffer.writeln(
      promptFragmentId != null
          ? 'prompt_fragment_id: $promptFragmentId'
          : 'prompt_fragment_id: null',
    );
    if (summary != null && summary.isNotEmpty) {
      buffer.writeln('instruction_summary:');
      for (final line in summary.split('\n')) {
        buffer.writeln('  $line');
      }
    }
    return buffer.toString().trimRight();
  }
}

class StateTransitionCommand
    implements Query<StateTransitionInput, StateTransitionOutput> {
  @override
  final StateTransitionInput input;
  final BranchProvider branchProvider;
  final GitCommandRunner gitCommandRunner;
  final Assets? _assets;

  StateTransitionCommand(
    this.input, {
    BranchProvider? branchProvider,
    GitCommandRunner? gitCommandRunner,
    Assets? assets,
  }) : branchProvider = branchProvider ?? _defaultBranchProvider,
       gitCommandRunner = gitCommandRunner ?? _defaultGitCommandRunner,
       _assets = assets;

  @override
  String? validate() => null;

  @override
  Future<StateTransitionOutput> execute() async {
    if (input.event == null || input.event!.trim().isEmpty) {
      throw CommandException(
        id: 'missing-event',
        message: 'Missing required flag --event for state transition',
        exitCode: ExitCode.validationFailed,
      );
    }

    final projectRoot =
        getProjectRoot(input.workingDirectory) ?? input.workingDirectory;
    final contractPath = _assets != null
        ? _assets.path('fsm/transition_contract.yaml')
        : p.join(projectRoot, 'assets', 'fsm', 'transition_contract.yaml');
    final contract = parseFsmContract(File(contractPath).readAsStringSync());

    final current = input.currentState != null
        ? FsmState.fromValue(input.currentState!.trim().toUpperCase())
        : _loadCurrentState(input.workingDirectory);
    final event = FsmEvent.fromValue(input.event!.trim().toLowerCase());
    final resolvedIssue = _resolveIssue(input.workingDirectory, input.issue);
    final executor = EffectExecutor(
      workingDirectory: input.workingDirectory,
      assets: _assets,
    );

    final transition = contract.transitionFor(current, event);
    if (!transition.allowed) {
      final message = transition.reason ?? 'Illegal transition';
      _recordBlockedRunTrace(
        executor,
        currentState: current.value,
        event: event.value,
        nextState: transition.to?.value,
        operationsExecuted: const ['validate_transition'],
        issue: resolvedIssue,
        reason: message,
        blockingBoundary: 'transition_matrix',
        authoritativeSurface: p.posix.join(
          'assets',
          'fsm',
          'transition_contract.yaml',
        ),
      );
      return StateTransitionOutput(
        allowed: false,
        currentState: current.value,
        event: event.value,
        nextState: null,
        operationsExecuted: const ['validate_transition'],
        promptFragmentId: null,
        requiredRole: null,
        requiredInstructions: null,
        message: message,
        code: ExitCode.invalidUsage,
      );
    }

    final branch = await branchProvider(input.workingDirectory);
    final retryContext = executor.retryContextFor(
      currentState: current.value,
      event: event.value,
    );
    if (retryContext != null) {
      executor.recordRetryTrace(
        currentState: current.value,
        event: event.value,
        triggeringFailure: retryContext.triggeringFailure,
        retryCount: retryContext.retryCount,
        operationsExecuted: const ['validate_transition'],
        issue: resolvedIssue,
        promptFragmentId: transition.operations?.promptFragmentId,
      );
    }

    final precheckResult = await _validatePreconditions(
      transition,
      input.workingDirectory,
      branch: branch,
      issue: resolvedIssue,
      currentState: current.value,
      promptFragmentId: transition.operations?.promptFragmentId,
      executor: executor,
    );
    if (precheckResult != null) {
      _recordBlockedRunTrace(
        executor,
        currentState: current.value,
        event: event.value,
        nextState: transition.to?.value,
        operationsExecuted: const ['validate_transition', 'validate_prechecks'],
        issue: resolvedIssue,
        promptFragmentId: transition.operations?.promptFragmentId,
        reason: precheckResult,
        blockingBoundary: _blockingBoundaryForFailure(precheckResult),
        authoritativeSurface: _authoritativeSurfaceForFailure(
          precheckResult,
          branch: branch,
          transition: transition,
          issue: resolvedIssue,
        ),
      );
      return StateTransitionOutput(
        allowed: false,
        currentState: current.value,
        event: event.value,
        nextState: null,
        operationsExecuted: const ['validate_transition', 'validate_prechecks'],
        promptFragmentId: null,
        requiredRole: null,
        requiredInstructions: null,
        message: precheckResult,
        code: ExitCode.validationFailed,
      );
    }

    final boundaryCommitSpec = _boundaryCommitSpec(
      transition.operations?.commitPolicy ?? 'none',
      branch: branch,
      issue: resolvedIssue,
    );
    final boundaryCommitResult = await _executeBoundaryCommit(
      transition,
      input.workingDirectory,
      executor: executor,
      currentState: current.value,
      event: event.value,
      branch: branch,
      issue: resolvedIssue,
      promptFragmentId: transition.operations?.promptFragmentId,
    );
    _recordBoundaryCommitSensorTrace(
      executor,
      currentState: current.value,
      transition: transition,
      spec: boundaryCommitSpec,
      errorMessage: boundaryCommitResult.errorMessage,
      issue: resolvedIssue,
    );
    if (boundaryCommitResult.errorMessage != null) {
      _recordBlockedRunTrace(
        executor,
        currentState: current.value,
        event: event.value,
        nextState: transition.to?.value,
        operationsExecuted: const ['validate_transition', 'validate_prechecks'],
        issue: resolvedIssue,
        promptFragmentId: transition.operations?.promptFragmentId,
        reason: boundaryCommitResult.errorMessage!,
        blockingBoundary: 'boundary_commit',
        authoritativeSurface:
            _boundaryCommitSpec(
              transition.operations?.commitPolicy ?? 'none',
              branch: branch,
              issue: resolvedIssue,
            )?.path ??
            'git:commit',
      );
      return StateTransitionOutput(
        allowed: false,
        currentState: current.value,
        event: event.value,
        nextState: null,
        operationsExecuted: const ['validate_transition', 'validate_prechecks'],
        promptFragmentId: null,
        requiredRole: null,
        requiredInstructions: null,
        message: boundaryCommitResult.errorMessage!,
        code: ExitCode.genericError,
      );
    }

    final operations = transition.operations;
    final promptId = operations?.promptFragmentId;
    final prompt = promptId != null ? contract.promptFragments[promptId] : null;
    final instructions = prompt?.instructions;
    final instructionSummary = instructions == null || instructions.isEmpty
        ? null
        : _loadInstructionSummary(instructions, projectRoot);

    // Execute CLI-side effects
    final executedEffects = executor.executeAll(
      effects: operations?.effects ?? const <String>[],
      newState: transition.to?.value ?? current.value,
      currentState: current.value,
      event: event.value,
      issue: resolvedIssue,
      promptFragmentId: promptId,
    );

    return StateTransitionOutput(
      allowed: true,
      currentState: current.value,
      event: event.value,
      nextState: transition.to?.value,
      operationsExecuted: <String>[
        'validate_transition',
        'validate_prechecks',
        ...boundaryCommitResult.operationsExecuted,
        ...executedEffects,
      ],
      promptFragmentId: promptId,
      requiredRole: prompt?.role,
      requiredInstructions: prompt?.instructions,
      instructionSummary: instructionSummary,
      message:
          'Transition ${current.value} --${event.value}--> ${transition.to?.value}',
      code: ExitCode.ok,
    );
  }

  void _recordBlockedRunTrace(
    EffectExecutor executor, {
    required String currentState,
    required String event,
    required String? nextState,
    required List<String> operationsExecuted,
    required String reason,
    required String blockingBoundary,
    required String authoritativeSurface,
    String? issue,
    String? promptFragmentId,
  }) {
    executor.recordTransitionTrace(
      currentState: currentState,
      event: event,
      newState: nextState,
      operationsExecuted: operationsExecuted,
      outcome: 'blocked',
      issue: issue,
      promptFragmentId: promptFragmentId,
      reason: reason,
    );
    executor.recordBlockTrace(
      currentState: currentState,
      event: event,
      blockingBoundary: blockingBoundary,
      reason: reason,
      authoritativeSurface: authoritativeSurface,
      operationsExecuted: operationsExecuted,
      issue: issue,
      promptFragmentId: promptFragmentId,
    );
  }

  String _prePrInspectionSensorVerdict(_PrePrInspectionReport report) {
    if (!report.exists || report.verdict == null) {
      return 'MISSING';
    }
    if (!report.hasRequiredPassStructure ||
        report.hasMissingRequiredCitations) {
      return 'INVALID';
    }
    if (report.verdict == 'APPROVED' && report.hasFailChecks) {
      return 'INVALID';
    }
    return report.verdict!;
  }

  void _recordBoundaryCommitSensorTrace(
    EffectExecutor executor, {
    required String currentState,
    required FsmTransition transition,
    required _BoundaryCommitSpec? spec,
    required String? errorMessage,
    String? issue,
  }) {
    if (spec == null) return;

    executor.recordSensorRunTrace(
      currentState: currentState,
      sensorCategory: 'pre_transition',
      gate: _boundaryCommitGate(spec),
      verdict: errorMessage == null ? 'APPROVED' : 'FAILED',
      authority: spec.path,
      operationsExecuted: const ['validate_transition', 'validate_prechecks'],
      issue: issue,
      promptFragmentId: transition.operations?.promptFragmentId,
    );
  }

  String _boundaryCommitGate(_BoundaryCommitSpec spec) {
    if (spec.path.endsWith('/analyze')) {
      return 'commit_analysis_boundary';
    }
    if (spec.path.endsWith('/plan.md')) {
      return 'commit_plan_boundary';
    }
    return 'boundary_commit';
  }

  String _blockingBoundaryForFailure(String message) {
    if (message.startsWith('ERROR_PRECONDITION_PRE_PR_INSPECTION_')) {
      return 'end_pre_pr_gate';
    }
    return 'precondition_gate';
  }

  String _authoritativeSurfaceForFailure(
    String message, {
    required String branch,
    required FsmTransition transition,
    String? issue,
  }) {
    if (message.startsWith('ERROR_PRECONDITION_DIAGNOSIS_MISSING')) {
      return p.posix.join('cleanrooms', branch, 'analyze', 'diagnosis.md');
    }
    if (message.startsWith('ERROR_PRECONDITION_ANALYZE_INDEX_MISSING')) {
      return p.posix.join('cleanrooms', branch, 'analyze', 'index.md');
    }
    if (message.startsWith('ERROR_PRECONDITION_CONFIRMATIONS_MISSING')) {
      return p.posix.join('cleanrooms', branch, 'analyze', 'confirmations.md');
    }
    if (message.startsWith('ERROR_PRECONDITION_PLAN_MISSING')) {
      return p.posix.join('cleanrooms', branch, 'plan.md');
    }
    if (message.startsWith('ERROR_PRECONDITION_PRE_PR_INSPECTION_')) {
      return p.posix.join('cleanrooms', branch, 'pre_pr_inspection.md');
    }
    if (message.startsWith('ERROR_PRECONDITION_ISSUE_FIRST')) {
      return p.posix.join('cleanrooms', branch, kStateFileName);
    }
    if (message.startsWith('ERROR_PRECONDITION_BRANCH_POLICY')) {
      return 'git:branch';
    }

    return _boundaryCommitSpec(
          transition.operations?.commitPolicy ?? 'none',
          branch: branch,
          issue: issue,
        )?.path ??
        p.posix.join('assets', 'fsm', 'transition_contract.yaml');
  }

  String? _loadInstructionSummary(
    List<String> instructions,
    String projectRoot,
  ) {
    for (final assets in _instructionAssetCandidates(projectRoot)) {
      if (!_hasInstructionAssets(assets, instructions)) {
        continue;
      }
      return InstructionPromptLoader(assets: assets).loadMany(instructions);
    }
    return null;
  }

  Iterable<Assets> _instructionAssetCandidates(String projectRoot) sync* {
    final assets = _assets;
    if (assets != null) {
      yield assets;
    }

    yield Assets(root: projectRoot);

    final currentRoot = Directory.current.path;
    if (currentRoot != projectRoot) {
      yield Assets(root: currentRoot);
    }
  }

  bool _hasInstructionAssets(Assets assets, List<String> instructions) {
    return instructions.every(
      (name) => File(assets.path('instructions/$name.md')).existsSync(),
    );
  }

  Future<String?> _validatePreconditions(
    FsmTransition transition,
    String workingDirectory, {
    required String branch,
    required String currentState,
    required EffectExecutor executor,
    String? issue,
    String? promptFragmentId,
  }) async {
    final prechecks = transition.operations?.prechecks ?? const <String>[];
    final issueSelected = issue != null && issue.trim().isNotEmpty;

    if (prechecks.contains('issue_selected_or_created')) {
      if (!issueSelected) {
        _recordPrecheckSensor(
          executor,
          currentState: currentState,
          precheck: 'issue_selected_or_created',
          verdict: 'MISSING',
          branch: branch,
          issue: issue,
          promptFragmentId: promptFragmentId,
        );
        return 'ERROR_PRECONDITION_ISSUE_FIRST: Create/select issue before commitment actions';
      }
      _recordPrecheckSensor(
        executor,
        currentState: currentState,
        precheck: 'issue_selected_or_created',
        verdict: 'APPROVED',
        branch: branch,
        issue: issue,
        promptFragmentId: promptFragmentId,
      );
    }

    if (prechecks.contains('issue_selected')) {
      if (!issueSelected) {
        _recordPrecheckSensor(
          executor,
          currentState: currentState,
          precheck: 'issue_selected',
          verdict: 'MISSING',
          branch: branch,
          issue: issue,
          promptFragmentId: promptFragmentId,
        );
        return 'ERROR_PRECONDITION_ISSUE_FIRST: Create/select issue before commitment actions';
      }
      _recordPrecheckSensor(
        executor,
        currentState: currentState,
        precheck: 'issue_selected',
        verdict: 'APPROVED',
        branch: branch,
        issue: issue,
        promptFragmentId: promptFragmentId,
      );
    }

    if (prechecks.contains('feature_branch_selected')) {
      if (!_isIssueLinkedFeatureBranch(branch, issue)) {
        _recordPrecheckSensor(
          executor,
          currentState: currentState,
          precheck: 'feature_branch_selected',
          verdict: 'INVALID',
          branch: branch,
          issue: issue,
          promptFragmentId: promptFragmentId,
        );
        return _branchPolicyError(branch: branch, issue: issue);
      }
      _recordPrecheckSensor(
        executor,
        currentState: currentState,
        precheck: 'feature_branch_selected',
        verdict: 'APPROVED',
        branch: branch,
        issue: issue,
        promptFragmentId: promptFragmentId,
      );
    }

    if (prechecks.contains('diagnosis_exists')) {
      if (!_analysisDiagnosisExists(branch, workingDirectory)) {
        _recordPrecheckSensor(
          executor,
          currentState: currentState,
          precheck: 'diagnosis_exists',
          verdict: 'MISSING',
          branch: branch,
          issue: issue,
          promptFragmentId: promptFragmentId,
        );
        return 'ERROR_PRECONDITION_DIAGNOSIS_MISSING: diagnosis.md missing for current issue branch';
      }
      _recordPrecheckSensor(
        executor,
        currentState: currentState,
        precheck: 'diagnosis_exists',
        verdict: 'APPROVED',
        branch: branch,
        issue: issue,
        promptFragmentId: promptFragmentId,
      );
    }

    if (prechecks.contains('diagnosis_structured')) {
      final missingSections = _missingDiagnosisSections(
        branch,
        workingDirectory,
      );
      if (missingSections.isNotEmpty) {
        _recordPrecheckSensor(
          executor,
          currentState: currentState,
          precheck: 'diagnosis_structured',
          verdict: 'INVALID',
          branch: branch,
          issue: issue,
          promptFragmentId: promptFragmentId,
        );
        return 'ERROR_PRECONDITION_DIAGNOSIS_STRUCTURE_INVALID: diagnosis.md must contain Evidence, Hypotheses, Constraints, and Open Questions sections for current issue branch; missing: ${missingSections.join(', ')}';
      }
      _recordPrecheckSensor(
        executor,
        currentState: currentState,
        precheck: 'diagnosis_structured',
        verdict: 'APPROVED',
        branch: branch,
        issue: issue,
        promptFragmentId: promptFragmentId,
      );
    }

    if (prechecks.contains('diagnosis_evidence_present')) {
      if (!_diagnosisHasConcreteEvidence(branch, workingDirectory)) {
        _recordPrecheckSensor(
          executor,
          currentState: currentState,
          precheck: 'diagnosis_evidence_present',
          verdict: 'INVALID',
          branch: branch,
          issue: issue,
          promptFragmentId: promptFragmentId,
        );
        return 'ERROR_PRECONDITION_DIAGNOSIS_EVIDENCE_MISSING: diagnosis.md Evidence section must contain concrete observed evidence before PLAN handoff; replace the bootstrap placeholder with actual repo, artifact, test, runtime, or research evidence';
      }
      _recordPrecheckSensor(
        executor,
        currentState: currentState,
        precheck: 'diagnosis_evidence_present',
        verdict: 'APPROVED',
        branch: branch,
        issue: issue,
        promptFragmentId: promptFragmentId,
      );
    }

    if (prechecks.contains('diagnosis_evidence_verifiable')) {
      final unverifiable = _unverifiableEvidenceBullets(
        branch,
        workingDirectory,
      );
      if (unverifiable == null || unverifiable.isNotEmpty) {
        _recordPrecheckSensor(
          executor,
          currentState: currentState,
          precheck: 'diagnosis_evidence_verifiable',
          verdict: 'INVALID',
          branch: branch,
          issue: issue,
          promptFragmentId: promptFragmentId,
        );
        final offenders = (unverifiable == null || unverifiable.isEmpty)
            ? ''
            : ' Bullets missing a handle: ${unverifiable.take(3).map((b) => '"${b.length > 70 ? '${b.substring(0, 70)}…' : b}"').join('; ')}';
        return 'ERROR_PRECONDITION_DIAGNOSIS_EVIDENCE_UNVERIFIABLE: every diagnosis.md Evidence bullet must carry a re-checkable handle (a file:line reference, a URL, or an inline-code command/test id) so each claim can be reopened and verified.$offenders';
      }
      _recordPrecheckSensor(
        executor,
        currentState: currentState,
        precheck: 'diagnosis_evidence_verifiable',
        verdict: 'APPROVED',
        branch: branch,
        issue: issue,
        promptFragmentId: promptFragmentId,
      );
    }

    if (prechecks.contains('index_exists')) {
      if (!_analysisIndexExists(branch, workingDirectory)) {
        _recordPrecheckSensor(
          executor,
          currentState: currentState,
          precheck: 'index_exists',
          verdict: 'MISSING',
          branch: branch,
          issue: issue,
          promptFragmentId: promptFragmentId,
        );
        return 'ERROR_PRECONDITION_ANALYZE_INDEX_MISSING: index.md missing for current issue branch';
      }
      _recordPrecheckSensor(
        executor,
        currentState: currentState,
        precheck: 'index_exists',
        verdict: 'APPROVED',
        branch: branch,
        issue: issue,
        promptFragmentId: promptFragmentId,
      );
    }

    if (prechecks.contains('confirmations_exists')) {
      if (!_analysisConfirmationsExists(branch, workingDirectory)) {
        _recordPrecheckSensor(
          executor,
          currentState: currentState,
          precheck: 'confirmations_exists',
          verdict: 'MISSING',
          branch: branch,
          issue: issue,
          promptFragmentId: promptFragmentId,
        );
        return 'ERROR_PRECONDITION_CONFIRMATIONS_MISSING: confirmations.md missing for current issue branch';
      }
      _recordPrecheckSensor(
        executor,
        currentState: currentState,
        precheck: 'confirmations_exists',
        verdict: 'APPROVED',
        branch: branch,
        issue: issue,
        promptFragmentId: promptFragmentId,
      );
    }

    if (prechecks.contains('plan_approved')) {
      if (!_planExists(branch, workingDirectory)) {
        _recordPrecheckSensor(
          executor,
          currentState: currentState,
          precheck: 'plan_approved',
          verdict: 'MISSING',
          branch: branch,
          issue: issue,
          promptFragmentId: promptFragmentId,
        );
        return 'ERROR_PRECONDITION_PLAN_MISSING: plan.md missing for current issue branch';
      }
      _recordPrecheckSensor(
        executor,
        currentState: currentState,
        precheck: 'plan_approved',
        verdict: 'APPROVED',
        branch: branch,
        issue: issue,
        promptFragmentId: promptFragmentId,
      );
    }

    if (prechecks.contains('plan_executable_checks')) {
      if (!_planHasExecutableChecks(branch, workingDirectory)) {
        _recordPrecheckSensor(
          executor,
          currentState: currentState,
          precheck: 'plan_executable_checks',
          verdict: 'INVALID',
          branch: branch,
          issue: issue,
          promptFragmentId: promptFragmentId,
        );
        return 'ERROR_PRECONDITION_PLAN_CHECKS_NOT_EXECUTABLE: plan.md must verify phases with executable checks (a test runner command or a test-file reference), not pseudocode; provide at least one executable check, and at least one per phase';
      }
      _recordPrecheckSensor(
        executor,
        currentState: currentState,
        precheck: 'plan_executable_checks',
        verdict: 'APPROVED',
        branch: branch,
        issue: issue,
        promptFragmentId: promptFragmentId,
      );
    }

    if (prechecks.contains('pre_pr_inspection_approved')) {
      PrePrInspectionRunner(
        workingDirectory: workingDirectory,
        assets: _assets,
      ).refreshDeterministicPasses();
      final report = _prePrInspectionReport(branch, workingDirectory);
      final verdict = _prePrInspectionSensorVerdict(report);
      _recordPrecheckSensor(
        executor,
        currentState: currentState,
        precheck: 'pre_pr_inspection_approved',
        verdict: verdict,
        branch: branch,
        issue: issue,
        promptFragmentId: promptFragmentId,
      );
      if (!report.exists || report.verdict == null) {
        return 'ERROR_PRECONDITION_PRE_PR_INSPECTION_MISSING: pre_pr_inspection.md missing or verdict not found for current issue branch';
      }
      if (!report.hasRequiredPassStructure) {
        return 'ERROR_PRECONDITION_PRE_PR_INSPECTION_INVALID: pre_pr_inspection.md must contain Consistency, Completeness, and Traceability sections with PASS, FAIL, or WARN checks';
      }
      if (report.hasMissingRequiredCitations) {
        return 'ERROR_PRECONDITION_PRE_PR_INSPECTION_INVALID: FAIL checks in pre_pr_inspection.md must include repo-relative file:line citations';
      }
      if (report.verdict == 'APPROVED' && report.hasFailChecks) {
        return 'ERROR_PRECONDITION_PRE_PR_INSPECTION_INVALID: pre_pr_inspection.md cannot declare APPROVED while any pass contains FAIL checks';
      }
      if (report.verdict != 'APPROVED') {
        return 'ERROR_PRECONDITION_PRE_PR_INSPECTION_BLOCKED: pre_pr_inspection.md verdict is ${report.verdict}';
      }
    }

    return null;
  }

  void _recordPrecheckSensor(
    EffectExecutor executor, {
    required String currentState,
    required String precheck,
    required String verdict,
    required String branch,
    String? issue,
    String? promptFragmentId,
  }) {
    executor.recordSensorRunTrace(
      currentState: currentState,
      sensorCategory: _sensorCategoryForPrecheck(precheck),
      gate: precheck,
      verdict: verdict,
      authority: _authoritySurfaceForPrecheck(precheck, branch),
      operationsExecuted: const ['validate_transition', 'validate_prechecks'],
      issue: issue,
      promptFragmentId: promptFragmentId,
    );
  }

  String _sensorCategoryForPrecheck(String precheck) {
    switch (precheck) {
      case 'issue_selected':
      case 'issue_selected_or_created':
      case 'feature_branch_selected':
        return 'runtime';
      case 'pre_pr_inspection_approved':
        return 'pre_pr';
      default:
        return 'pre_transition';
    }
  }

  String _authoritySurfaceForPrecheck(String precheck, String branch) {
    switch (precheck) {
      case 'issue_selected':
      case 'issue_selected_or_created':
        return branch.isEmpty
            ? kStateFileName
            : p.posix.join('cleanrooms', branch, kStateFileName);
      case 'feature_branch_selected':
        return 'git:branch';
      case 'diagnosis_exists':
      case 'diagnosis_structured':
      case 'diagnosis_evidence_verifiable':
        return p.posix.join('cleanrooms', branch, 'analyze', 'diagnosis.md');
      case 'index_exists':
        return p.posix.join('cleanrooms', branch, 'analyze', 'index.md');
      case 'confirmations_exists':
        return p.posix.join(
          'cleanrooms',
          branch,
          'analyze',
          'confirmations.md',
        );
      case 'plan_approved':
      case 'plan_executable_checks':
        return p.posix.join('cleanrooms', branch, 'plan.md');
      case 'pre_pr_inspection_approved':
        return p.posix.join('cleanrooms', branch, 'pre_pr_inspection.md');
      default:
        return p.posix.join('assets', 'fsm', 'transition_contract.yaml');
    }
  }

  List<String> _missingDiagnosisSections(
    String branch,
    String workingDirectory,
  ) {
    final content = _readDiagnosisContent(branch, workingDirectory);
    if (content == null) {
      return _diagnosisSectionPatterns.keys.toList(growable: false);
    }

    return _diagnosisSectionPatterns.entries
        .where((entry) => !entry.value.hasMatch(content))
        .map((entry) => entry.key)
        .toList(growable: false);
  }

  bool _diagnosisHasConcreteEvidence(String branch, String workingDirectory) {
    final content = _readDiagnosisContent(branch, workingDirectory);
    if (content == null) return false;

    final evidenceBody = _diagnosisSectionBody(
      content,
      _diagnosisSectionPatterns['Evidence']!,
    );
    if (evidenceBody == null) return false;

    final normalizedLines = evidenceBody
        .split('\n')
        .map(_normalizeDiagnosisSectionLine)
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (normalizedLines.isEmpty) return false;

    return normalizedLines.any(
      (line) => line.toLowerCase() != _diagnosisEvidenceBootstrapPlaceholder,
    );
  }

  /// Evidence bullets that lack a re-checkable handle. Empty = all verifiable;
  /// null = the Evidence section is unreadable/empty (a structural problem
  /// surfaced by other prechecks).
  List<String>? _unverifiableEvidenceBullets(
    String branch,
    String workingDirectory,
  ) {
    final content = _readDiagnosisContent(branch, workingDirectory);
    if (content == null) return null;

    final evidenceBody = _diagnosisSectionBody(
      content,
      _diagnosisSectionPatterns['Evidence']!,
    );
    if (evidenceBody == null) return null;

    final bullets = evidenceBody
        .split('\n')
        .map(_normalizeDiagnosisSectionLine)
        .where((line) => line.isNotEmpty)
        .where(
          (line) =>
              line.toLowerCase() != _diagnosisEvidenceBootstrapPlaceholder,
        )
        .toList(growable: false);
    if (bullets.isEmpty) return null;

    return bullets
        .where((b) => !_evidenceLineHasVerifiableHandle(b))
        .toList(growable: false);
  }

  /// A re-checkable evidence handle: a URL, a `file:line` reference, or an
  /// inline-code span (a command, test id, or backtick-quoted path).
  bool _evidenceLineHasVerifiableHandle(String line) {
    final url = RegExp(r'https?://\S+');
    final fileLine = RegExp(r'[\w./\\-]+\.[A-Za-z0-9]+:\d+');
    final inlineCode = RegExp('`[^`]+`');
    return url.hasMatch(line) ||
        fileLine.hasMatch(line) ||
        inlineCode.hasMatch(line);
  }

  String? _readDiagnosisContent(String branch, String workingDirectory) {
    if (branch.isEmpty) return null;

    final diagnosisPath = p.join(
      workingDirectory,
      'cleanrooms',
      branch,
      'analyze',
      'diagnosis.md',
    );
    final file = File(diagnosisPath);
    if (!file.existsSync()) return null;
    return file.readAsStringSync();
  }

  /// Whether plan.md verifies its work with executable checks rather than
  /// pseudocode: at least one executable handle overall, and — when the plan
  /// is organized in phases — at least as many handles as phase headings.
  bool _planHasExecutableChecks(String branch, String workingDirectory) {
    final content = _readPlanContent(branch, workingDirectory);
    if (content == null) return false;

    final lines = content.split('\n');
    final phaseHeading = RegExp(r'^#{2,4}\s+.*\bphase\b', caseSensitive: false);
    final phaseCount = lines.where(phaseHeading.hasMatch).length;
    final handleCount = lines.where(_planLineHasExecutableHandle).length;

    if (handleCount == 0) return false;
    return handleCount >= phaseCount;
  }

  /// An executable verification handle: a test-runner command in inline code,
  /// or a reference to a test file/dir.
  bool _planLineHasExecutableHandle(String line) {
    final runner = RegExp(
      r'(?:dart test|flutter test|npm (?:test|run)|pytest|python3?\s+(?:-c|-m|[^\s`]+\.py)|go test|cargo test|mocha|jest)',
      caseSensitive: false,
    );
    final testFile = RegExp(
      r'(?:_test\.\w+|\.test\.\w+|_spec\.\w+|(?:^|[\s/`])test/)',
      caseSensitive: false,
    );
    return runner.hasMatch(line) || testFile.hasMatch(line);
  }

  String? _readPlanContent(String branch, String workingDirectory) {
    if (branch.isEmpty) return null;
    final planPath = p.join(workingDirectory, 'cleanrooms', branch, 'plan.md');
    final file = File(planPath);
    if (!file.existsSync()) return null;
    return file.readAsStringSync();
  }

  String? _diagnosisSectionBody(String content, RegExp sectionPattern) {
    final lines = content.split('\n');
    final headingPattern = RegExp(r'^##?\s+');
    final buffer = <String>[];
    var inSection = false;

    for (final line in lines) {
      if (!inSection) {
        if (sectionPattern.hasMatch(line)) {
          inSection = true;
        }
        continue;
      }

      if (headingPattern.hasMatch(line)) {
        break;
      }
      buffer.add(line);
    }

    if (!inSection) return null;
    return buffer.join('\n').trim();
  }

  String _normalizeDiagnosisSectionLine(String line) {
    var normalized = line.trim();
    normalized = normalized.replaceFirst(RegExp(r'^[-*]\s+'), '');
    normalized = normalized.replaceFirst(RegExp(r'^>\s*'), '');
    return normalized.trim();
  }

  Future<_BoundaryCommitResult> _executeBoundaryCommit(
    FsmTransition transition,
    String workingDirectory, {
    required EffectExecutor executor,
    required String currentState,
    required String event,
    required String branch,
    String? issue,
    String? promptFragmentId,
  }) async {
    final policy = transition.operations?.commitPolicy ?? 'none';
    final spec = _boundaryCommitSpec(policy, branch: branch, issue: issue);
    if (spec == null) {
      return const _BoundaryCommitResult.success();
    }

    if (!_isIssueLinkedFeatureBranch(branch, issue)) {
      return _BoundaryCommitResult.failure(
        'ERROR_BOUNDARY_COMMIT_BRANCH_POLICY: Cannot create ${spec.label} commit without an issue-linked feature branch',
      );
    }

    final stageResult = await gitCommandRunner(workingDirectory, [
      'add',
      '--',
      spec.path,
    ]);
    executor.recordToolActivityTrace(
      currentState: currentState,
      event: event,
      toolClass: 'git',
      commandFamily: 'add',
      outcome: stageResult.exitCode == 0 ? 'succeeded' : 'failed',
      exitCode: stageResult.exitCode,
      authority: spec.path,
      operationsExecuted: const [
        'validate_transition',
        'create_boundary_commit',
      ],
      issue: issue,
      promptFragmentId: promptFragmentId,
    );
    if (stageResult.exitCode != 0) {
      return _BoundaryCommitResult.failure(
        'ERROR_BOUNDARY_COMMIT_FAILED: Failed to stage ${spec.label} artifacts: ${_gitError(stageResult)}',
      );
    }

    final commitResult = await gitCommandRunner(workingDirectory, [
      'commit',
      '-m',
      spec.message,
      '--only',
      '--',
      spec.path,
    ]);
    executor.recordToolActivityTrace(
      currentState: currentState,
      event: event,
      toolClass: 'git',
      commandFamily: 'commit',
      outcome: commitResult.exitCode == 0 ? 'succeeded' : 'failed',
      exitCode: commitResult.exitCode,
      authority: spec.path,
      operationsExecuted: const [
        'validate_transition',
        'create_boundary_commit',
      ],
      issue: issue,
      promptFragmentId: promptFragmentId,
    );
    if (commitResult.exitCode != 0) {
      return _BoundaryCommitResult.failure(
        'ERROR_BOUNDARY_COMMIT_FAILED: Failed to create ${spec.label} commit: ${_gitError(commitResult)}',
      );
    }

    return const _BoundaryCommitResult.success(
      operationsExecuted: ['create_boundary_commit'],
    );
  }

  /// The branch-policy failure, written to teach: it names the expected pattern,
  /// gives a concrete example, shows the actual branch, and points at the command
  /// that produces a valid branch in one step (AC2).
  String _branchPolicyError({required String branch, String? issue}) {
    final issueRef = (issue != null && issue.trim().isNotEmpty)
        ? issue.trim()
        : '<issue>';
    final actual = branch.trim().isEmpty ? '(no branch)' : branch.trim();
    return 'ERROR_PRECONDITION_BRANCH_POLICY: the current branch "$actual" is not '
        'linked to issue #$issueRef.\n'
        'Expected a branch named "<NNN>-<slug>" that starts with "$issueRef-" '
        '(e.g. "$issueRef-fix-login"). A branch under a prefix like '
        '"feat/$issueRef-…" does NOT qualify — the name must be a single segment.\n'
        // `--apply --autoapprove`: this message is acted on by the scheduler,
        // which has no terminal to be asked on. Inquiry gates at state
        // completion, not at every command — an approval prompt here would
        // stall the very agent the remediation is written for. A person typing
        // it by hand can drop `--autoapprove` to be asked, or pass `--plan` to
        // only look.
        'Create it and enter ANALYZE in one step with: '
        'iq implementation start --issue $issueRef --apply --autoapprove';
  }

  bool _isIssueLinkedFeatureBranch(String branch, String? issue) {
    final normalizedBranch = branch.trim();
    if (normalizedBranch.isEmpty ||
        normalizedBranch == 'main' ||
        normalizedBranch == 'master') {
      return false;
    }

    final normalizedIssue = issue?.trim();
    if (normalizedIssue == null || normalizedIssue.isEmpty) {
      return false;
    }

    final canonicalIssue =
        int.tryParse(normalizedIssue)?.toString() ?? normalizedIssue;
    final validPrefixes = <String>{'$canonicalIssue-'};
    if (canonicalIssue.length < 3) {
      validPrefixes.add('${canonicalIssue.padLeft(3, '0')}-');
    }

    return validPrefixes.any(normalizedBranch.startsWith);
  }

  _BoundaryCommitSpec? _boundaryCommitSpec(
    String policy, {
    required String branch,
    String? issue,
  }) {
    switch (policy) {
      case 'commit_analysis_boundary':
        return _BoundaryCommitSpec(
          label: 'analysis boundary',
          path: p.posix.join('cleanrooms', branch, 'analyze'),
          message: _boundaryCommitMessage('analysis', issue),
        );
      case 'commit_plan_boundary':
        return _BoundaryCommitSpec(
          label: 'plan boundary',
          path: p.posix.join('cleanrooms', branch, 'plan.md'),
          message: _boundaryCommitMessage('plan', issue),
        );
      default:
        return null;
    }
  }

  String _boundaryCommitMessage(String boundary, String? issue) {
    final suffix = issue != null && issue.trim().isNotEmpty
        ? ' for #$issue'
        : '';
    return 'approve $boundary boundary$suffix';
  }

  String _gitError(ProcessResult result) {
    final stderr = result.stderr.toString().trim();
    if (stderr.isNotEmpty) {
      return stderr;
    }

    final stdout = result.stdout.toString().trim();
    if (stdout.isNotEmpty) {
      return stdout;
    }

    return 'git exited with code ${result.exitCode}';
  }

  bool _analysisDiagnosisExists(String branch, String workingDirectory) {
    if (branch.isEmpty) return false;
    final diagnosisPath = p.join(
      workingDirectory,
      'cleanrooms',
      branch,
      'analyze',
      'diagnosis.md',
    );
    return File(diagnosisPath).existsSync();
  }

  bool _analysisIndexExists(String branch, String workingDirectory) {
    if (branch.isEmpty) return false;
    final indexPath = p.join(
      workingDirectory,
      'cleanrooms',
      branch,
      'analyze',
      'index.md',
    );
    return File(indexPath).existsSync();
  }

  bool _analysisConfirmationsExists(String branch, String workingDirectory) {
    if (branch.isEmpty) return false;
    final confirmationsPath = p.join(
      workingDirectory,
      'cleanrooms',
      branch,
      'analyze',
      'confirmations.md',
    );
    return File(confirmationsPath).existsSync();
  }

  _PrePrInspectionReport _prePrInspectionReport(
    String branch,
    String workingDirectory,
  ) {
    if (branch.isEmpty) {
      return const _PrePrInspectionReport(
        exists: false,
        verdict: null,
        checksByPass: <String, List<_PrePrInspectionCheck>>{},
      );
    }

    final projectRoot = getProjectRoot(workingDirectory) ?? workingDirectory;
    final reportPath = p.join(
      projectRoot,
      'cleanrooms',
      branch,
      'pre_pr_inspection.md',
    );
    final file = File(reportPath);
    if (!file.existsSync()) {
      return const _PrePrInspectionReport(
        exists: false,
        verdict: null,
        checksByPass: <String, List<_PrePrInspectionCheck>>{},
      );
    }

    final content = file.readAsStringSync();

    final match = RegExp(
      r'^verdict:\s*([A-Za-z_\-]+)\s*$',
      multiLine: true,
    ).firstMatch(content);

    final checksByPass = <String, List<_PrePrInspectionCheck>>{};
    String? currentPass;
    for (final rawLine in content.split('\n')) {
      final line = rawLine.trim();
      if (line.startsWith('## ')) {
        currentPass = _normalizeInspectionPass(line.substring(3).trim());
        if (currentPass != null) {
          checksByPass.putIfAbsent(
            currentPass,
            () => <_PrePrInspectionCheck>[],
          );
        }
        continue;
      }

      final checkMatch = _inspectionCheckPattern.firstMatch(line);
      if (checkMatch != null && currentPass != null) {
        checksByPass[currentPass]!.add(
          _PrePrInspectionCheck(
            status: checkMatch.group(1)!.toUpperCase(),
            detail: checkMatch.group(2)!.trim(),
          ),
        );
      }
    }

    return _PrePrInspectionReport(
      exists: true,
      verdict: match?.group(1)?.trim().toUpperCase(),
      checksByPass: checksByPass,
    );
  }

  String? _normalizeInspectionPass(String heading) {
    final normalizedHeading = heading.toLowerCase();
    for (final pass in _requiredInspectionPasses) {
      if (normalizedHeading.contains(pass.toLowerCase())) {
        return pass;
      }
    }
    return null;
  }

  bool _planExists(String branch, String workingDirectory) {
    if (branch.isEmpty) return false;
    final planPath = p.join(workingDirectory, 'cleanrooms', branch, 'plan.md');
    return File(planPath).existsSync();
  }

  String? _resolveIssue(String workingDirectory, String? inputIssue) {
    if (inputIssue != null && inputIssue.trim().isNotEmpty) {
      return inputIssue.trim();
    }
    return InquiryState.load(workingDirectory).issue;
  }

  FsmState _loadCurrentState(String workingDirectory) {
    final phase = InquiryState.load(workingDirectory).state;
    if (phase.trim().isEmpty) return FsmState.idle;
    return FsmState.fromValue(phase.trim().toUpperCase());
  }

  static Future<String> _defaultBranchProvider(String workingDirectory) async {
    final result = await Process.run('git', [
      'rev-parse',
      '--abbrev-ref',
      'HEAD',
    ], workingDirectory: workingDirectory);
    if (result.exitCode != 0) return '';
    return result.stdout.toString().trim();
  }

  static Future<ProcessResult> _defaultGitCommandRunner(
    String workingDirectory,
    List<String> arguments,
  ) {
    return Process.run('git', arguments, workingDirectory: workingDirectory);
  }
}
