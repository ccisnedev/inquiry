import 'dart:io';

import 'package:inquiry_cli/assets.dart';
import 'package:inquiry_cli/modules/ape/commands/prompt.dart';
import 'package:inquiry_cli/modules/ape/inquiry_state.dart';
import 'package:inquiry_cli/src/git_utils.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmpDir;
  late String stateFilePath;

  const branch = '145-test-branch';

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('ape_prompt_test_');

    // Cycle-local state lives at cleanrooms/<branch>/.iq.state.yaml.
    Directory(p.join(tmpDir.path, '.inquiry')).createSync();
    _initGitRepo(tmpDir.path, branch: branch);
    Directory(
      p.join(tmpDir.path, 'cleanrooms', branch),
    ).createSync(recursive: true);
    stateFilePath = p.join(tmpDir.path, 'cleanrooms', branch, kStateFileName);

    // Copy assets/apes/ from real assets
    final apesDir = Directory(p.join(tmpDir.path, 'assets', 'apes'));
    apesDir.createSync(recursive: true);
    for (final name in ['socrates', 'dewey', 'descartes', 'ada', 'darwin']) {
      File(
        'assets/apes/$name.yaml',
      ).copySync(p.join(apesDir.path, '$name.yaml'));
    }

    final statesDir = Directory(p.join(tmpDir.path, 'assets', 'fsm', 'states'));
    statesDir.createSync(recursive: true);
    for (final name in [
      'idle',
      'analyze',
      'plan',
      'execute',
      'end',
      'evolution',
    ]) {
      File(
        'assets/fsm/states/$name.yaml',
      ).copySync(p.join(statesDir.path, '$name.yaml'));
    }

    final fsmDir = Directory(p.join(tmpDir.path, 'assets', 'fsm'));
    fsmDir.createSync(recursive: true);
    File(
      'assets/fsm/transition_contract.yaml',
    ).copySync(p.join(fsmDir.path, 'transition_contract.yaml'));

    final instructionsDir = Directory(
      p.join(tmpDir.path, 'assets', 'instructions'),
    );
    instructionsDir.createSync(recursive: true);
    for (final name in [
      'doc-read',
      'doc-write',
      'coding-manifesto-review',
      'issue-create',
      'inquiry-end',
      'inquiry-start',
    ]) {
      File(
        'assets/instructions/$name.md',
      ).copySync(p.join(instructionsDir.path, '$name.md'));
    }
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  void writeState(String state, {String? issue, String? promptFragmentId}) {
    File(stateFilePath).writeAsStringSync(
      'state: $state\n'
      'issue: ${issue ?? 'null'}\n',
      mode: FileMode.write,
    );

    if (promptFragmentId != null) {
      File(stateFilePath).writeAsStringSync(
        'prompt_fragment_id: $promptFragmentId\n',
        mode: FileMode.append,
      );
    }
  }

  void writeStateWithApe(
    String state, {
    String? issue,
    String? promptFragmentId,
    required String apeName,
    required String apeState,
  }) {
    File(stateFilePath).writeAsStringSync(
      'state: $state\n'
      'issue: ${issue != null ? '"$issue"' : 'null'}\n'
      '${promptFragmentId != null ? 'prompt_fragment_id: $promptFragmentId\n' : ''}'
      'ape:\n'
      '  name: $apeName\n'
      '  state: $apeState\n',
    );
  }

  group('ApePromptCommand', () {
    group('successful prompt assembly', () {
      test('socrates in ANALYZE returns base prompt', () async {
        writeState('ANALYZE', issue: '99');
        final cmd = ApePromptCommand(
          ApePromptInput(name: 'socrates', workingDirectory: tmpDir.path),
        );
        final result = await cmd.execute();

        expect(result.apeName, equals('socrates'));
        expect(result.fsmState, equals('ANALYZE'));
        expect(result.subState, isNull);
        expect(result.prompt, contains('SOCRATES'));
        expect(result.prompt, contains('Socratic method'));
      });

      test(
        'socrates with sub-state clarification appends state prompt',
        () async {
          writeState('ANALYZE');
          final cmd = ApePromptCommand(
            ApePromptInput(
              name: 'socrates',
              subState: 'clarification',
              workingDirectory: tmpDir.path,
            ),
          );
          final result = await cmd.execute();

          expect(result.subState, equals('clarification'));
          expect(result.prompt, contains('SOCRATES'));
          expect(result.prompt, contains('Clarification questions'));
        },
      );

      test('descartes in PLAN returns base prompt', () async {
        writeState('PLAN');
        final cmd = ApePromptCommand(
          ApePromptInput(name: 'descartes', workingDirectory: tmpDir.path),
        );
        final result = await cmd.execute();

        expect(result.apeName, equals('descartes'));
        expect(result.fsmState, equals('PLAN'));
        expect(result.prompt, contains('DESCARTES'));
        expect(result.prompt, contains('scientific method'));
        expect(result.prompt, contains('enumerate every construction site'));
        expect(result.prompt, contains('object literals, factory returns'));
      });

      test(
        'injects transition-owned instruction summary when prompt_fragment_id exists',
        () async {
          writeState('PLAN', issue: '145', promptFragmentId: 'analyze_to_plan');

          final cmd = ApePromptCommand(
            ApePromptInput(
              name: 'descartes',
              subState: 'decomposition',
              workingDirectory: tmpDir.path,
            ),
          );
          final result = await cmd.execute();

          final stateIndex = result.prompt.indexOf('FOCUS: Division.');
          final instructionIndex = result.prompt.indexOf(
            'Write inside the CLI-created template and keep frontmatter unchanged.',
          );
          final contractIndex = result.prompt.indexOf(
            '## Phase-Owned Operational Contract',
          );

          expect(instructionIndex, greaterThan(stateIndex));
          expect(contractIndex, greaterThan(instructionIndex));
          expect(result.prompt, isNot(contains('## When to Use')));
        },
      );

      test(
        'does not inject transition-owned summary when prompt_fragment_id is absent',
        () async {
          writeState('PLAN', issue: '145');

          final cmd = ApePromptCommand(
            ApePromptInput(
              name: 'descartes',
              subState: 'decomposition',
              workingDirectory: tmpDir.path,
            ),
          );
          final result = await cmd.execute();

          expect(
            result.prompt,
            isNot(
              contains(
                'Write inside the CLI-created template and keep frontmatter unchanged.',
              ),
            ),
          );
        },
      );

      test('ada in EXECUTE returns base prompt', () async {
        writeState('EXECUTE');
        final cmd = ApePromptCommand(
          ApePromptInput(name: 'ada', workingDirectory: tmpDir.path),
        );
        final result = await cmd.execute();

        expect(result.apeName, equals('ada'));
        expect(result.fsmState, equals('EXECUTE'));
        expect(result.prompt, contains('ADA'));
        expect(result.prompt, contains('INTENTION FIRST'));
      });

      test(
        'records model_activity with prompt size and assembly time',
        () async {
          writeState(
            'ANALYZE',
            issue: '145',
            promptFragmentId: 'idle_to_analyze',
          );

          final cmd = ApePromptCommand(
            ApePromptInput(name: 'socrates', workingDirectory: tmpDir.path),
          );
          final result = await cmd.execute();

          final traceContent = File(
            p.join(tmpDir.path, 'cleanrooms', branch, 'run_trace.yaml'),
          ).readAsStringSync();

          expect(traceContent, contains('event_class: model_activity'));
          expect(traceContent, contains('phase: ANALYZE'));
          expect(traceContent, contains('ape_name: socrates'));
          expect(traceContent, contains('model_surface: prompt_input'));
          expect(
            traceContent,
            contains('prompt_characters: ${result.prompt.runes.length}'),
          );
          expect(traceContent, contains('estimated_input_tokens: '));
          expect(traceContent, contains('assembly_duration_seconds: '));
          expect(traceContent, contains('prompt_fragment_id: idle_to_analyze'));
        },
      );

      test('darwin in EVOLUTION returns base prompt', () async {
        writeState('EVOLUTION');
        final cmd = ApePromptCommand(
          ApePromptInput(name: 'darwin', workingDirectory: tmpDir.path),
        );
        final result = await cmd.execute();

        expect(result.apeName, equals('darwin'));
        expect(result.fsmState, equals('EVOLUTION'));
        expect(result.prompt, contains('DARWIN'));
        expect(result.prompt, contains('natural selection'));
      });

      test('dewey in IDLE returns base prompt', () async {
        writeStateWithApe('IDLE', apeName: 'dewey', apeState: 'evaluate_scope');
        final cmd = ApePromptCommand(
          ApePromptInput(name: 'dewey', workingDirectory: tmpDir.path),
        );
        final result = await cmd.execute();

        expect(result.apeName, equals('dewey'));
        expect(result.fsmState, equals('IDLE'));
        expect(result.subState, equals('evaluate_scope'));
        expect(result.prompt, contains('well-formed issue'));
        expect(result.prompt, contains('FOCUS: Scope evaluation.'));
      });
    });

    group('MISSING_NAME', () {
      test('throws CommandException when name flag is null', () async {
        writeState('ANALYZE');
        final cmd = ApePromptCommand(
          ApePromptInput(name: null, workingDirectory: tmpDir.path),
        );

        expect(
          () => cmd.execute(),
          throwsA(
            isA<CommandException>()
                .having((e) => e.id, 'id', equals('missing-name'))
                .having(
                  (e) => e.exitCode,
                  'exitCode',
                  equals(ExitCode.validationFailed),
                ),
          ),
        );
      });
    });

    group('MISSING_NAME', () {
      test('throws CommandException when name flag is null', () async {
        writeState('ANALYZE');
        final cmd = ApePromptCommand(
          ApePromptInput(name: null, workingDirectory: tmpDir.path),
        );

        expect(
          () => cmd.execute(),
          throwsA(
            isA<CommandException>()
                .having((e) => e.id, 'id', equals('missing-name'))
                .having(
                  (e) => e.exitCode,
                  'exitCode',
                  equals(ExitCode.validationFailed),
                ),
          ),
        );
      });
    });

    group('APE_NOT_FOUND', () {
      test('throws for nonexistent APE', () async {
        writeState('ANALYZE');
        final cmd = ApePromptCommand(
          ApePromptInput(name: 'nonexistent', workingDirectory: tmpDir.path),
        );

        expect(
          () => cmd.execute(),
          throwsA(
            isA<CommandException>()
                .having((e) => e.id, 'id', equals('ape-not-found'))
                .having(
                  (e) => e.exitCode,
                  'exitCode',
                  equals(ExitCode.notFound),
                ),
          ),
        );
      });
    });

    group('APE_NOT_ACTIVE', () {
      test('socrates in EXECUTE throws not active', () async {
        writeState('EXECUTE');
        final cmd = ApePromptCommand(
          ApePromptInput(name: 'socrates', workingDirectory: tmpDir.path),
        );

        expect(
          () => cmd.execute(),
          throwsA(
            isA<CommandException>()
                .having((e) => e.id, 'id', equals('ape-not-active'))
                .having(
                  (e) => e.exitCode,
                  'exitCode',
                  equals(ExitCode.conflict),
                ),
          ),
        );
      });

      test('descartes in ANALYZE throws not active', () async {
        writeState('ANALYZE');
        final cmd = ApePromptCommand(
          ApePromptInput(name: 'descartes', workingDirectory: tmpDir.path),
        );

        expect(
          () => cmd.execute(),
          throwsA(
            isA<CommandException>()
                .having((e) => e.id, 'id', equals('ape-not-active'))
                .having(
                  (e) => e.exitCode,
                  'exitCode',
                  equals(ExitCode.conflict),
                ),
          ),
        );
      });

      test('ada in END throws not active', () async {
        writeState('END');
        final cmd = ApePromptCommand(
          ApePromptInput(name: 'ada', workingDirectory: tmpDir.path),
        );

        expect(
          () => cmd.execute(),
          throwsA(
            isA<CommandException>()
                .having((e) => e.id, 'id', equals('ape-not-active'))
                .having(
                  (e) => e.exitCode,
                  'exitCode',
                  equals(ExitCode.conflict),
                ),
          ),
        );
      });

      test('socrates-idle in IDLE throws not active', () async {
        writeStateWithApe('IDLE', apeName: 'dewey', apeState: 'evaluate_scope');
        File(
          p.join(tmpDir.path, 'assets', 'apes', 'socrates-idle.yaml'),
        ).writeAsStringSync(
          File('assets/apes/dewey.yaml').readAsStringSync().replaceFirst(
            'name: dewey',
            'name: socrates-idle',
          ),
        );
        final cmd = ApePromptCommand(
          ApePromptInput(name: 'socrates-idle', workingDirectory: tmpDir.path),
        );

        expect(
          () => cmd.execute(),
          throwsA(
            isA<CommandException>()
                .having((e) => e.id, 'id', equals('ape-not-active'))
                .having(
                  (e) => e.exitCode,
                  'exitCode',
                  equals(ExitCode.conflict),
                ),
          ),
        );
      });
    });

    group('unknown sub-state', () {
      test('throws for invalid sub-state name', () async {
        writeState('ANALYZE');
        final cmd = ApePromptCommand(
          ApePromptInput(
            name: 'socrates',
            subState: 'nonexistent_state',
            workingDirectory: tmpDir.path,
          ),
        );

        expect(() => cmd.execute(), throwsA(isA<ArgumentError>()));
      });
    });

    group('output format', () {
      test('toJson includes all fields', () async {
        writeState('ANALYZE');
        final cmd = ApePromptCommand(
          ApePromptInput(
            name: 'socrates',
            subState: 'evidence',
            workingDirectory: tmpDir.path,
          ),
        );
        final result = await cmd.execute();
        final json = result.toJson();

        expect(json['ape'], equals('socrates'));
        expect(json['fsm_state'], equals('ANALYZE'));
        expect(json['sub_state'], equals('evidence'));
        expect(json['prompt'], isA<String>());
      });

      test('toText returns raw prompt', () async {
        writeState('PLAN');
        final cmd = ApePromptCommand(
          ApePromptInput(name: 'descartes', workingDirectory: tmpDir.path),
        );
        final result = await cmd.execute();

        expect(result.toText(), equals(result.prompt));
      });
    });

    group('missing .inquiry/state.yaml', () {
      test('defaults to IDLE when no state file exists', () async {
        // Delete the state file if it exists
        final stateFile = File(stateFilePath);
        if (stateFile.existsSync()) stateFile.deleteSync();

        final cmd = ApePromptCommand(
          ApePromptInput(name: 'socrates', workingDirectory: tmpDir.path),
        );

        // In IDLE, no APE is active → should throw APE_NOT_ACTIVE
        expect(
          () => cmd.execute(),
          throwsA(
            isA<CommandException>()
                .having((e) => e.id, 'id', equals('ape-not-active'))
                .having(
                  (e) => e.exitCode,
                  'exitCode',
                  equals(ExitCode.conflict),
                ),
          ),
        );
      });
    });

    group('validate', () {
      test('returns null for empty name (validation moved to execute)', () {
        final cmd = ApePromptCommand(
          ApePromptInput(name: '', workingDirectory: tmpDir.path),
        );
        expect(cmd.validate(), isNull);
      });

      test('returns null for valid name', () {
        final cmd = ApePromptCommand(
          ApePromptInput(name: 'socrates', workingDirectory: tmpDir.path),
        );
        expect(cmd.validate(), isNull);
      });
    });

    group('prompt fidelity — regression vs monolith', () {
      test('socrates prompt covers key Socratic method concepts', () async {
        writeState('ANALYZE');
        final cmd = ApePromptCommand(
          ApePromptInput(
            name: 'socrates',
            subState: 'clarification',
            workingDirectory: tmpDir.path,
          ),
        );
        final result = await cmd.execute();

        expect(result.prompt, contains('EPISTEMIC HUMILITY'));
        expect(result.prompt, contains('MIDWIFE OF IDEAS'));
        expect(result.prompt, contains('Clarification questions'));
        expect(result.prompt, contains('## Phase-Owned Operational Contract'));
        expect(result.prompt, contains('diagnosis.md'));
      });

      test('descartes prompt covers Cartesian method', () async {
        writeState('PLAN');
        final cmd = ApePromptCommand(
          ApePromptInput(
            name: 'descartes',
            subState: 'decomposition',
            workingDirectory: tmpDir.path,
          ),
        );
        final result = await cmd.execute();

        expect(result.prompt, contains('EVIDENCE'));
        expect(result.prompt, contains('DIVISION'));
        expect(result.prompt, contains('experimental plan'));
        expect(result.prompt, contains('Division'));
      });

      test('ada prompt covers the programming manifesto', () async {
        writeState('EXECUTE');
        final cmd = ApePromptCommand(
          ApePromptInput(
            name: 'ada',
            subState: 'compose_change',
            workingDirectory: tmpDir.path,
          ),
        );
        final result = await cmd.execute();

        expect(result.prompt, contains('INTENTION FIRST'));
        expect(result.prompt, contains("REWRITE, DON'T PATCH"));
        expect(result.prompt, contains('FOCUS: Composition.'));
      });

      test('darwin prompt covers evolution process', () async {
        writeState('EVOLUTION');
        final cmd = ApePromptCommand(
          ApePromptInput(
            name: 'darwin',
            subState: 'observe',
            workingDirectory: tmpDir.path,
          ),
        );
        final result = await cmd.execute();

        expect(result.prompt, contains('natural selection'));
        expect(
          result.prompt,
          contains('ideal Analyze -> Plan -> Execute -> End loop'),
        );
        expect(
          result.prompt,
          contains(
            'EVOLUTION owns the repository procedure for issue search/comment/create and metrics collection.',
          ),
        );
        expect(result.prompt, contains('Observation'));
      });
    });

    group('auto-read sub-state from state.yaml', () {
      test('reads ape.state when no --state flag', () async {
        writeStateWithApe(
          'ANALYZE',
          issue: '145',
          apeName: 'socrates',
          apeState: 'evidence',
        );

        final cmd = ApePromptCommand(
          ApePromptInput(name: 'socrates', workingDirectory: tmpDir.path),
        );
        final result = await cmd.execute();

        expect(result.subState, equals('evidence'));
        expect(result.prompt, contains('Evidence'));
      });

      test('--state flag overrides ape.state from state.yaml', () async {
        writeStateWithApe(
          'ANALYZE',
          issue: '145',
          apeName: 'socrates',
          apeState: 'evidence',
        );

        final cmd = ApePromptCommand(
          ApePromptInput(
            name: 'socrates',
            subState: 'clarification',
            workingDirectory: tmpDir.path,
          ),
        );
        final result = await cmd.execute();

        expect(result.subState, equals('clarification'));
        expect(result.prompt, contains('Clarification'));
      });

      test('works with ada ape sub-state', () async {
        writeStateWithApe(
          'EXECUTE',
          issue: '145',
          apeName: 'ada',
          apeState: 'manifesto_review',
        );

        final cmd = ApePromptCommand(
          ApePromptInput(name: 'ada', workingDirectory: tmpDir.path),
        );
        final result = await cmd.execute();

        expect(result.subState, equals('manifesto_review'));
        expect(result.prompt, contains('FOCUS: Manifesto review.'));
      });
    });

    group('inquiry-context injection', () {
      late Directory gitTmpDir;

      void expectExplicitContextAfter(String prompt, String promptFragment) {
        final promptIndex = prompt.indexOf(promptFragment);
        final contextIndex = prompt.indexOf('# --- inquiry-context ---');

        expect(
          promptIndex,
          greaterThanOrEqualTo(0),
          reason: 'Missing assembled prompt fragment: $promptFragment',
        );
        expect(
          contextIndex,
          greaterThan(promptIndex),
          reason: 'inquiry-context should stay explicit after the prompt body',
        );
      }

      void expectOperationalContractBetween(
        String prompt, {
        required String identityFragment,
        required String contractFragment,
      }) {
        final identityIndex = prompt.indexOf(identityFragment);
        final contractIndex = prompt.indexOf(
          '## Phase-Owned Operational Contract',
        );
        final detailIndex = prompt.indexOf(contractFragment);
        final contextIndex = prompt.indexOf('# --- inquiry-context ---');

        expect(
          identityIndex,
          greaterThanOrEqualTo(0),
          reason:
              'Missing assembled prompt identity fragment: $identityFragment',
        );
        expect(
          contractIndex,
          greaterThan(identityIndex),
          reason: 'Operational contract should come after the APE identity',
        );
        expect(
          detailIndex,
          greaterThan(contractIndex),
          reason: 'Operational contract should expose the phase-owned details',
        );
        expect(
          contextIndex,
          greaterThan(detailIndex),
          reason:
              'inquiry-context should stay explicit after the operational contract',
        );
      }

      void expectContextKeyOnlyInInquiryContext(String prompt, String key) {
        final contextIndex = prompt.indexOf('# --- inquiry-context ---');
        final keyIndex = prompt.indexOf(key);

        expect(
          contextIndex,
          greaterThanOrEqualTo(0),
          reason: 'Missing inquiry-context block for key: $key',
        );
        expect(
          keyIndex,
          greaterThan(contextIndex),
          reason:
              '$key should be owned by inquiry-context, not the APE identity',
        );
        expect(
          prompt.indexOf(key, keyIndex + key.length),
          equals(-1),
          reason: '$key should appear only once in the assembled prompt',
        );
      }

      void expectContextFieldOnlyInInquiryContext(String prompt, String key) {
        final contextIndex = prompt.indexOf('# --- inquiry-context ---');
        final keyToken = '$key:';
        final keyIndex = prompt.indexOf(keyToken);

        expect(
          contextIndex,
          greaterThanOrEqualTo(0),
          reason: 'Missing inquiry-context block for field: $key',
        );
        expect(
          keyIndex,
          greaterThan(contextIndex),
          reason: '$key should be owned by inquiry-context, not prompt prose',
        );
        expect(
          prompt.indexOf(keyToken, keyIndex + keyToken.length),
          equals(-1),
          reason: '$key should appear only once in the assembled prompt',
        );
      }

      String expectedProjectRoot() =>
          getProjectRoot(gitTmpDir.path) ?? p.normalize(gitTmpDir.path);

      setUp(() {
        gitTmpDir = Directory.systemTemp.createTempSync('ape_ctx_test_');
        Directory(p.join(gitTmpDir.path, '.inquiry')).createSync();

        // Init a git repo with a branch and initial commit
        Process.runSync('git', ['init'], workingDirectory: gitTmpDir.path);
        Process.runSync('git', [
          'config',
          'user.email',
          'test@test.com',
        ], workingDirectory: gitTmpDir.path);
        Process.runSync('git', [
          'config',
          'user.name',
          'Test',
        ], workingDirectory: gitTmpDir.path);
        File(p.join(gitTmpDir.path, '.gitkeep')).writeAsStringSync('');
        Process.runSync('git', ['add', '.'], workingDirectory: gitTmpDir.path);
        Process.runSync('git', [
          'commit',
          '-m',
          'init',
        ], workingDirectory: gitTmpDir.path);
        Process.runSync('git', [
          'checkout',
          '-b',
          '152-test-branch',
        ], workingDirectory: gitTmpDir.path);
        Directory(
          p.join(gitTmpDir.path, 'cleanrooms', '152-test-branch'),
        ).createSync(recursive: true);

        // Copy ape YAMLs
        final apesDir = Directory(p.join(gitTmpDir.path, 'assets', 'apes'));
        apesDir.createSync(recursive: true);
        for (final name in [
          'socrates',
          'dewey',
          'descartes',
          'ada',
          'darwin',
        ]) {
          File(
            'assets/apes/$name.yaml',
          ).copySync(p.join(apesDir.path, '$name.yaml'));
        }

        final fsmDir = Directory(p.join(gitTmpDir.path, 'assets', 'fsm'));
        fsmDir.createSync(recursive: true);
        File(
          'assets/fsm/transition_contract.yaml',
        ).copySync(p.join(fsmDir.path, 'transition_contract.yaml'));

        final instructionsDir = Directory(
          p.join(gitTmpDir.path, 'assets', 'instructions'),
        );
        instructionsDir.createSync(recursive: true);
        for (final name in [
          'doc-read',
          'doc-write',
          'coding-manifesto-review',
          'issue-create',
          'inquiry-end',
          'inquiry-start',
        ]) {
          File(
            'assets/instructions/$name.md',
          ).copySync(p.join(instructionsDir.path, '$name.md'));
        }

        final statesDir = Directory(
          p.join(gitTmpDir.path, 'assets', 'fsm', 'states'),
        );
        statesDir.createSync(recursive: true);
        for (final name in [
          'idle',
          'analyze',
          'plan',
          'execute',
          'end',
          'evolution',
        ]) {
          File(
            'assets/fsm/states/$name.yaml',
          ).copySync(p.join(statesDir.path, '$name.yaml'));
        }
      });

      tearDown(() {
        gitTmpDir.deleteSync(recursive: true);
      });

      test('socrates prompt includes inquiry-context with output_dir', () async {
        File(
          p.join(
            gitTmpDir.path,
            'cleanrooms',
            '152-test-branch',
            kStateFileName,
          ),
        ).writeAsStringSync('state: ANALYZE\nissue: "152"\n');

        final cmd = ApePromptCommand(
          ApePromptInput(
            name: 'socrates',
            subState: 'clarification',
            workingDirectory: gitTmpDir.path,
          ),
        );
        final result = await cmd.execute();

        expect(result.prompt, contains('diagnosis.md'));
        expect(result.prompt, contains('Clarification questions'));
        expect(
          result.prompt,
          contains(
            'Inspect repository state, existing cycle artifacts, project docs, and relevant tests or runtime evidence before asking the user for missing facts.',
          ),
        );
        expect(
          result.prompt,
          contains(
            'If repository evidence is insufficient, run targeted external research before escalating factual gaps to the user.',
          ),
        );
        expect(
          result.prompt,
          contains(
            'Ask the user only for unresolved facts, hidden constraints, or human judgments that evidence cannot recover.',
          ),
        );
        expect(
          result.prompt,
          contains(
            'Before asking a question, decide whether it would materially change the diagnosis, scope, or uncertainty of the problem.',
          ),
        );
        expect(
          result.prompt,
          contains(
            'Ask fewer than 2-3 questions when fewer are justified; diagnostic value matters more than question count.',
          ),
        );
        expect(
          result.prompt,
          contains(
            'If the problem is already sufficiently bounded, stop widening the interrogation and move toward synthesis.',
          ),
        );
        expect(
          result.prompt,
          contains(
            'When discussing methods, approaches, or tradeoffs, propose concrete candidate alternatives before asking the user to evaluate them.',
          ),
        );
        expect(result.prompt, contains('# --- inquiry-context ---'));
        expect(
          result.prompt,
          contains('project_root: ${expectedProjectRoot()}'),
        );
        expect(result.prompt, contains('task_id: 152'));
        expect(
          result.prompt,
          contains('output_dir: cleanrooms/152-test-branch/analyze/'),
        );
        expect(
          result.prompt,
          contains(
            'confirmations_doc: cleanrooms/152-test-branch/analyze/confirmations.md',
          ),
        );
        expect(
          result.prompt,
          contains('index_file: cleanrooms/152-test-branch/analyze/index.md'),
        );
        expect(result.prompt, contains('doc_protocol: doc-write'));
        expect(
          result.prompt,
          contains('context_policy: progressive-disclosure'),
        );
        expect(
          result.prompt,
          contains('authority_mode: build-authoritative-analysis'),
        );
        expect(
          result.prompt,
          contains(
            "upfront_context: ['cleanrooms/152-test-branch/issue.md', 'cleanrooms/152-test-branch/analyze/index.md']",
          ),
        );
        expect(
          result.prompt,
          contains(
            "retrieval_context: ['cleanrooms/152-test-branch/analyze/index.md', 'cleanrooms/152-test-branch/analyze/confirmations.md', '${expectedProjectRoot()}']",
          ),
        );
        expect(
          result.prompt,
          contains(
            "deferred_context: ['broad repository rereads not justified by the active uncertainty']",
          ),
        );
        expect(
          result.prompt,
          contains(
            'authoritative_handoff: cleanrooms/152-test-branch/analyze/diagnosis.md',
          ),
        );
        expect(
          result.prompt,
          contains(
            'authority_rule: diagnosis.md becomes the authoritative handoff to PLAN once written',
          ),
        );
        expect(
          result.prompt,
          contains(
            'retrieval_trigger_rule: widen retrieval only when the bounded analysis corpus leaves a named uncertainty unresolved',
          ),
        );
        expect(
          result.prompt,
          contains(
            'reread_avoidance_rule: do not restart repository-wide discovery when issue.md, index.md, and confirmations.md already bound the active uncertainty',
          ),
        );
        expect(result.prompt, contains('sensor_policy: minimum-phase-stack'));
        expect(
          result.prompt,
          contains(
            "minimum_sensor_stack: ['runtime', 'pre_transition', 'inferential_optional']",
          ),
        );
        expect(
          result.prompt,
          contains("blocking_sensor_stack: ['runtime', 'pre_transition']"),
        );
        expect(
          result.prompt,
          contains("advisory_sensor_stack: ['inferential_optional']"),
        );
        expect(result.prompt, contains('sensor_gate: handoff-to-plan'));
        expect(
          result.prompt,
          contains(
            'sensor_authority_rule: analysis corpus and diagnosis handoff must be complete enough before PLAN handoff can proceed',
          ),
        );
        expect(
          result.prompt,
          contains('observability_policy: minimum-phase-trace'),
        );
        expect(
          result.prompt,
          contains(
            'execution_trace_surface: cleanrooms/152-test-branch/run_trace.yaml',
          ),
        );
        expect(
          result.prompt,
          contains(
            "trace_targets: ['transition', 'sensor_run', 'block', 'retry', 'phase_timing', 'tool_activity']",
          ),
        );
        expect(
          result.prompt,
          contains("eval_targets: ['evidence_discipline_failure']"),
        );
        expect(result.prompt, contains('evidence_policy: evidence-first'));
        expect(
          result.prompt,
          contains(
            "evidence_acquisition_order: ['repo', 'cycle_artifacts', 'docs', 'tests', 'runtime_evidence', 'web_research', 'user_questions']",
          ),
        );
        expect(
          result.prompt,
          contains(
            'question_escalation_rule: ask the user only after repo, cycle artifact, docs, tests, runtime evidence, and targeted web research leave a material uncertainty',
          ),
        );
        expect(
          result.prompt,
          contains(
            "diagnosis_requirements: ['record concrete observed evidence before handoff', 'distinguish observed evidence from hypotheses', 'record constraints explicitly', 'record open questions only when evidence cannot close them']",
          ),
        );
        expect(result.prompt, isNot(contains('confirmed_doc')));
        expect(result.prompt, isNot(contains('confirmed.md')));
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'output_dir: cleanrooms/152-test-branch/analyze/',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'project_root: ${expectedProjectRoot()}',
        );
        expectContextKeyOnlyInInquiryContext(result.prompt, 'task_id: 152');
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'confirmations_doc: cleanrooms/152-test-branch/analyze/confirmations.md',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'index_file: cleanrooms/152-test-branch/analyze/index.md',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'doc_protocol: doc-write',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'context_policy: progressive-disclosure',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'authority_mode: build-authoritative-analysis',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "upfront_context: ['cleanrooms/152-test-branch/issue.md', 'cleanrooms/152-test-branch/analyze/index.md']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "retrieval_context: ['cleanrooms/152-test-branch/analyze/index.md', 'cleanrooms/152-test-branch/analyze/confirmations.md', '${expectedProjectRoot()}']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "deferred_context: ['broad repository rereads not justified by the active uncertainty']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'authoritative_handoff: cleanrooms/152-test-branch/analyze/diagnosis.md',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'authority_rule: diagnosis.md becomes the authoritative handoff to PLAN once written',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'retrieval_trigger_rule: widen retrieval only when the bounded analysis corpus leaves a named uncertainty unresolved',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'reread_avoidance_rule: do not restart repository-wide discovery when issue.md, index.md, and confirmations.md already bound the active uncertainty',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'sensor_policy: minimum-phase-stack',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "minimum_sensor_stack: ['runtime', 'pre_transition', 'inferential_optional']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "blocking_sensor_stack: ['runtime', 'pre_transition']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "advisory_sensor_stack: ['inferential_optional']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'sensor_gate: handoff-to-plan',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'sensor_authority_rule: analysis corpus and diagnosis handoff must be complete enough before PLAN handoff can proceed',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'observability_policy: minimum-phase-trace',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'execution_trace_surface: cleanrooms/152-test-branch/run_trace.yaml',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "trace_targets: ['transition', 'sensor_run', 'block', 'retry', 'phase_timing', 'tool_activity']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "eval_targets: ['evidence_discipline_failure']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'evidence_policy: evidence-first',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "evidence_acquisition_order: ['repo', 'cycle_artifacts', 'docs', 'tests', 'runtime_evidence', 'web_research', 'user_questions']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'question_escalation_rule: ask the user only after repo, cycle artifact, docs, tests, runtime evidence, and targeted web research leave a material uncertainty',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "diagnosis_requirements: ['record concrete observed evidence before handoff', 'distinguish observed evidence from hypotheses', 'record constraints explicitly', 'record open questions only when evidence cannot close them']",
        );
        for (final key in [
          'evidence_acquisition_order',
          'diagnosis_requirements',
          'input_artifacts',
          'expected_outputs',
          'editable_surfaces',
          'read_only_surfaces',
          'validation_commands',
          'done_criteria',
          'minimum_sensor_stack',
          'blocking_sensor_stack',
          'advisory_sensor_stack',
          'upfront_context',
          'retrieval_context',
          'deferred_context',
          'retrieval_trigger_rule',
          'reread_avoidance_rule',
          'trace_targets',
          'eval_targets',
          'grader_stack',
        ]) {
          expectContextFieldOnlyInInquiryContext(result.prompt, key);
        }
        expectExplicitContextAfter(result.prompt, 'Clarification questions');
      });

      test('descartes prompt includes analysis_input path', () async {
        File(
          p.join(
            gitTmpDir.path,
            'cleanrooms',
            '152-test-branch',
            kStateFileName,
          ),
        ).writeAsStringSync('state: PLAN\nissue: "152"\n');

        final cmd = ApePromptCommand(
          ApePromptInput(
            name: 'descartes',
            subState: 'decomposition',
            workingDirectory: gitTmpDir.path,
          ),
        );
        final result = await cmd.execute();

        expect(result.prompt, contains('EVIDENCE'));
        expect(result.prompt, contains('FOCUS: Division.'));
        expect(result.prompt, contains('# --- inquiry-context ---'));
        expect(
          result.prompt,
          contains(
            'analysis_input: cleanrooms/152-test-branch/analyze/diagnosis.md',
          ),
        );
        expect(
          result.prompt,
          contains('plan_file: cleanrooms/152-test-branch/plan.md'),
        );
        expect(
          result.prompt,
          contains('project_root: ${expectedProjectRoot()}'),
        );
        expect(result.prompt, contains('task_id: 152'));
        expect(result.prompt, contains('doc_protocol: doc-read'));
        expect(
          result.prompt,
          contains('context_policy: authoritative-handoff'),
        );
        expect(
          result.prompt,
          contains('authority_mode: trust-diagnosis-first'),
        );
        expect(
          result.prompt,
          contains(
            "upfront_context: ['cleanrooms/152-test-branch/analyze/diagnosis.md']",
          ),
        );
        expect(
          result.prompt,
          contains(
            "retrieval_context: ['cleanrooms/152-test-branch/analyze/index.md', '${expectedProjectRoot()}']",
          ),
        );
        expect(
          result.prompt,
          contains(
            "deferred_context: ['reconstructing ANALYZE from broad rereads when diagnosis.md is already authoritative']",
          ),
        );
        expect(
          result.prompt,
          contains(
            'authoritative_handoff: cleanrooms/152-test-branch/analyze/diagnosis.md',
          ),
        );
        expect(
          result.prompt,
          contains(
            'authority_rule: trust diagnosis.md as the planning baseline unless a concrete gap requires targeted retrieval',
          ),
        );
        expect(
          result.prompt,
          contains(
            'retrieval_trigger_rule: retrieve adjacent repo evidence only when diagnosis.md leaves a concrete gap that would change plan structure, scope, or verification',
          ),
        );
        expect(
          result.prompt,
          contains(
            'reread_avoidance_rule: do not reconstruct ANALYZE from broad rereads when diagnosis.md already answers the planning question',
          ),
        );
        expect(result.prompt, contains('sensor_policy: minimum-phase-stack'));
        expect(
          result.prompt,
          contains(
            "minimum_sensor_stack: ['runtime', 'pre_transition', 'inferential_optional']",
          ),
        );
        expect(
          result.prompt,
          contains("blocking_sensor_stack: ['runtime', 'pre_transition']"),
        );
        expect(
          result.prompt,
          contains("advisory_sensor_stack: ['inferential_optional']"),
        );
        expect(result.prompt, contains('sensor_gate: handoff-to-execute'));
        expect(
          result.prompt,
          contains(
            'sensor_authority_rule: plan.md and issue-linked runtime context must be coherent before EXECUTE handoff',
          ),
        );
        expect(
          result.prompt,
          contains('observability_policy: minimum-phase-trace'),
        );
        expect(
          result.prompt,
          contains(
            "trace_targets: ['transition', 'sensor_run', 'block', 'retry', 'phase_timing', 'tool_activity']",
          ),
        );
        expect(
          result.prompt,
          contains("eval_targets: ['handoff_authority_failure']"),
        );
        expect(result.prompt, isNot(contains('Commit:')));
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'analysis_input: cleanrooms/152-test-branch/analyze/diagnosis.md',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'plan_file: cleanrooms/152-test-branch/plan.md',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'doc_protocol: doc-read',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'context_policy: authoritative-handoff',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'authority_mode: trust-diagnosis-first',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "upfront_context: ['cleanrooms/152-test-branch/analyze/diagnosis.md']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "retrieval_context: ['cleanrooms/152-test-branch/analyze/index.md', '${expectedProjectRoot()}']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "deferred_context: ['reconstructing ANALYZE from broad rereads when diagnosis.md is already authoritative']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'authoritative_handoff: cleanrooms/152-test-branch/analyze/diagnosis.md',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'authority_rule: trust diagnosis.md as the planning baseline unless a concrete gap requires targeted retrieval',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'retrieval_trigger_rule: retrieve adjacent repo evidence only when diagnosis.md leaves a concrete gap that would change plan structure, scope, or verification',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'reread_avoidance_rule: do not reconstruct ANALYZE from broad rereads when diagnosis.md already answers the planning question',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'sensor_policy: minimum-phase-stack',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "minimum_sensor_stack: ['runtime', 'pre_transition', 'inferential_optional']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "blocking_sensor_stack: ['runtime', 'pre_transition']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "advisory_sensor_stack: ['inferential_optional']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'sensor_gate: handoff-to-execute',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'sensor_authority_rule: plan.md and issue-linked runtime context must be coherent before EXECUTE handoff',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'observability_policy: minimum-phase-trace',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "trace_targets: ['transition', 'sensor_run', 'block', 'retry', 'phase_timing', 'tool_activity']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "eval_targets: ['handoff_authority_failure']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'project_root: ${expectedProjectRoot()}',
        );
        expectContextKeyOnlyInInquiryContext(result.prompt, 'task_id: 152');
        for (final key in [
          'input_artifacts',
          'expected_outputs',
          'editable_surfaces',
          'read_only_surfaces',
          'validation_commands',
          'done_criteria',
          'minimum_sensor_stack',
          'blocking_sensor_stack',
          'advisory_sensor_stack',
          'upfront_context',
          'retrieval_context',
          'deferred_context',
          'retrieval_trigger_rule',
          'reread_avoidance_rule',
          'trace_targets',
          'eval_targets',
          'grader_stack',
        ]) {
          expectContextFieldOnlyInInquiryContext(result.prompt, key);
        }
        expectExplicitContextAfter(result.prompt, 'FOCUS: Division.');
      });

      test(
        'task contract stays anchored to project root when invoked from a subdirectory',
        () async {
          File(
            p.join(
              gitTmpDir.path,
              'cleanrooms',
              '152-test-branch',
              kStateFileName,
            ),
          ).writeAsStringSync('state: ANALYZE\nissue: "152"\n');

          final nestedDir = Directory(
            p.join(gitTmpDir.path, 'lib', 'nested', 'deeper'),
          )..createSync(recursive: true);

          final cmd = ApePromptCommand(
            ApePromptInput(
              name: 'socrates',
              subState: 'clarification',
              workingDirectory: nestedDir.path,
            ),
            assets: Assets(root: gitTmpDir.path),
          );
          final result = await cmd.execute();

          expect(
            result.prompt,
            contains('project_root: ${expectedProjectRoot()}'),
          );
          expect(result.prompt, contains('task_id: 152'));
          expectContextKeyOnlyInInquiryContext(
            result.prompt,
            'project_root: ${expectedProjectRoot()}',
          );
          expectContextKeyOnlyInInquiryContext(result.prompt, 'task_id: 152');
          expectContextFieldOnlyInInquiryContext(
            result.prompt,
            'editable_surfaces',
          );
          expectContextFieldOnlyInInquiryContext(
            result.prompt,
            'done_criteria',
          );
        },
      );

      test('ada prompt includes plan contract in assembled prompt', () async {
        File(
          p.join(
            gitTmpDir.path,
            'cleanrooms',
            '152-test-branch',
            kStateFileName,
          ),
        ).writeAsStringSync(
          'state: EXECUTE\nissue: "152"\nprompt_fragment_id: plan_to_execute\n',
        );

        final cmd = ApePromptCommand(
          ApePromptInput(
            name: 'ada',
            subState: 'compose_change',
            workingDirectory: gitTmpDir.path,
          ),
        );
        final result = await cmd.execute();

        expect(result.prompt, contains('You are ADA'));
        expect(result.prompt, contains('INTENTION FIRST'));
        expect(
          result.prompt,
          contains('Read the changed slice before calling it complete.'),
        );
        expect(
          result.prompt,
          contains(
            'If the slice fails the manifesto, rewrite it instead of patching around the defect.',
          ),
        );
        expect(result.prompt, isNot(contains('## When to Use')));
        expect(result.prompt, contains('## Phase-Owned Operational Contract'));
        expect(
          result.prompt,
          contains(
            'Implement the plan phase by phase under its formal constraints.',
          ),
        );
        expect(result.prompt, contains('Follow plan.md phases in order'));
        expect(
          result.prompt,
          contains(
            'Review each changed slice against the active programming manifesto before calling the slice complete.',
          ),
        );
        expect(
          result.prompt,
          contains(
            'Treat validation as a named sensor stack, not as an informal checklist.',
          ),
        );
        expect(
          result.prompt,
          contains(
            'Minimum EXECUTE sensor stack: local_fast, pre_transition, pre_pr, runtime.',
          ),
        );
        expect(
          result.prompt,
          contains(
            'local_fast and pre_transition sensor failures block phase completion or phase advance',
          ),
        );
        expect(
          result.prompt,
          contains(
            'END handoff is blocked until the pre_pr sensor stack is complete',
          ),
        );
        expect(result.prompt, contains('Allowed actions:'));
        expect(result.prompt, contains('Edit code files'));
        expect(result.prompt, contains('# --- inquiry-context ---'));
        expect(
          result.prompt,
          contains('plan_file: cleanrooms/152-test-branch/plan.md'),
        );
        expect(
          result.prompt,
          contains('output_dir: cleanrooms/152-test-branch/'),
        );
        expect(result.prompt, contains('doc_protocol: doc-read'));
        expect(
          result.prompt,
          contains('context_policy: authoritative-handoff'),
        );
        expect(result.prompt, contains('authority_mode: trust-plan-first'));
        expect(
          result.prompt,
          contains("upfront_context: ['cleanrooms/152-test-branch/plan.md']"),
        );
        expect(
          result.prompt,
          contains(
            "retrieval_context: ['${expectedProjectRoot()}', 'cleanrooms/152-test-branch/']",
          ),
        );
        expect(
          result.prompt,
          contains(
            "deferred_context: ['re-reading broad analysis artifacts when plan.md already defines the bounded execution contract']",
          ),
        );
        expect(
          result.prompt,
          contains('authoritative_handoff: cleanrooms/152-test-branch/plan.md'),
        );
        expect(
          result.prompt,
          contains(
            'authority_rule: trust plan.md as the execution baseline unless implementation hits a concrete ambiguity that requires targeted retrieval',
          ),
        );
        expect(
          result.prompt,
          contains(
            'retrieval_trigger_rule: retrieve targeted code or cycle-local evidence only when plan.md leaves a concrete implementation or verification ambiguity',
          ),
        );
        expect(
          result.prompt,
          contains(
            'reread_avoidance_rule: do not re-read broad analysis artifacts when plan.md already defines the bounded execution contract',
          ),
        );
        expect(result.prompt, contains('sensor_policy: minimum-phase-stack'));
        expect(
          result.prompt,
          contains(
            "minimum_sensor_stack: ['local_fast', 'pre_transition', 'pre_pr', 'runtime']",
          ),
        );
        expect(
          result.prompt,
          contains(
            "blocking_sensor_stack: ['local_fast', 'pre_transition', 'runtime']",
          ),
        );
        expect(
          result.prompt,
          contains("advisory_sensor_stack: ['inferential_optional']"),
        );
        expect(result.prompt, contains('sensor_gate: handoff-to-end'));
        expect(
          result.prompt,
          contains(
            'sensor_authority_rule: pre_pr evidence must be complete before END handoff even when phase-local checks are green',
          ),
        );
        expect(
          result.prompt,
          contains('observability_policy: minimum-phase-trace'),
        );
        expect(
          result.prompt,
          contains('result_metrics_surface: .inquiry/metrics.yaml'),
        );
        expect(
          result.prompt,
          contains(
            'execution_trace_surface: cleanrooms/152-test-branch/run_trace.yaml',
          ),
        );
        expect(
          result.prompt,
          contains(
            "trace_targets: ['transition', 'sensor_run', 'block', 'retry', 'phase_timing', 'tool_activity']",
          ),
        );
        expect(
          result.prompt,
          contains('failure_taxonomy_surface: docs/spec/eval-model.md'),
        );
        expect(
          result.prompt,
          contains(
            'observability_authority_rule: execution_trace_surface and pre_pr_inspection_report outrank retrospective summaries when explaining EXECUTE cost or blocking',
          ),
        );
        expect(result.prompt, contains('eval_policy: harness-minimum'));
        expect(
          result.prompt,
          contains(
            "eval_targets: ['sensor_gate_failure', 'observability_failure']",
          ),
        );
        expect(
          result.prompt,
          contains(
            'failure_classification_mode: classify repeated failures as model, host, inquiry_harness, or mixed',
          ),
        );
        expect(
          result.prompt,
          contains(
            "grader_stack: ['structure_grader', 'trace_grader', 'artifact_consistency_grader']",
          ),
        );
        expect(
          result.prompt,
          contains(
            'eval_authority_rule: trace and gate artifacts outrank narrative retrospection when evaluating EXECUTE closure behavior',
          ),
        );
        expect(
          result.prompt,
          contains(
            'pre_pr_inspection_report: cleanrooms/152-test-branch/pre_pr_inspection.md',
          ),
        );
        expect(
          result.prompt,
          contains(
            'release_gate: propose semver bump and get explicit user approval before END handoff',
          ),
        );
        expect(
          result.prompt,
          contains(
            'changed slices satisfy the active coding manifesto before phase completion',
          ),
        );
        expect(
          result.prompt,
          contains(
            'semver bump proposal is explicit and user-approved before END handoff',
          ),
        );
        expect(result.prompt, isNot(contains('Run tests, lint, build')));
        expect(result.prompt, isNot(contains('retrospective.md')));
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'plan_file: cleanrooms/152-test-branch/plan.md',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'output_dir: cleanrooms/152-test-branch/',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'doc_protocol: doc-read',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'context_policy: authoritative-handoff',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'authority_mode: trust-plan-first',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "upfront_context: ['cleanrooms/152-test-branch/plan.md']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "retrieval_context: ['${expectedProjectRoot()}', 'cleanrooms/152-test-branch/']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "deferred_context: ['re-reading broad analysis artifacts when plan.md already defines the bounded execution contract']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'authoritative_handoff: cleanrooms/152-test-branch/plan.md',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'authority_rule: trust plan.md as the execution baseline unless implementation hits a concrete ambiguity that requires targeted retrieval',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'retrieval_trigger_rule: retrieve targeted code or cycle-local evidence only when plan.md leaves a concrete implementation or verification ambiguity',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'reread_avoidance_rule: do not re-read broad analysis artifacts when plan.md already defines the bounded execution contract',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'sensor_policy: minimum-phase-stack',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "minimum_sensor_stack: ['local_fast', 'pre_transition', 'pre_pr', 'runtime']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "blocking_sensor_stack: ['local_fast', 'pre_transition', 'runtime']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "advisory_sensor_stack: ['inferential_optional']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'sensor_gate: handoff-to-end',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'sensor_authority_rule: pre_pr evidence must be complete before END handoff even when phase-local checks are green',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'observability_policy: minimum-phase-trace',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'result_metrics_surface: .inquiry/metrics.yaml',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'execution_trace_surface: cleanrooms/152-test-branch/run_trace.yaml',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "trace_targets: ['transition', 'sensor_run', 'block', 'retry', 'phase_timing', 'tool_activity']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'failure_taxonomy_surface: docs/spec/eval-model.md',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'observability_authority_rule: execution_trace_surface and pre_pr_inspection_report outrank retrospective summaries when explaining EXECUTE cost or blocking',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'eval_policy: harness-minimum',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "eval_targets: ['sensor_gate_failure', 'observability_failure']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'failure_classification_mode: classify repeated failures as model, host, inquiry_harness, or mixed',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          "grader_stack: ['structure_grader', 'trace_grader', 'artifact_consistency_grader']",
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'eval_authority_rule: trace and gate artifacts outrank narrative retrospection when evaluating EXECUTE closure behavior',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'pre_pr_inspection_report: cleanrooms/152-test-branch/pre_pr_inspection.md',
        );
        expectContextKeyOnlyInInquiryContext(
          result.prompt,
          'release_gate: propose semver bump and get explicit user approval before END handoff',
        );
        for (final key in [
          'retrieval_trigger_rule',
          'reread_avoidance_rule',
          'minimum_sensor_stack',
          'blocking_sensor_stack',
          'advisory_sensor_stack',
          'trace_targets',
          'eval_targets',
          'grader_stack',
        ]) {
          expectContextFieldOnlyInInquiryContext(result.prompt, key);
        }
        expectOperationalContractBetween(
          result.prompt,
          identityFragment:
              'You are ADA, a programming assistant that writes code with intention, clarity, and craft.',
          contractFragment:
              'Implement the plan phase by phase under its formal constraints.',
        );
      });

      test(
        'dewey create_or_select prompt includes IDLE-owned routing context',
        () async {
          File(
            p.join(
              gitTmpDir.path,
              'cleanrooms',
              '152-test-branch',
              kStateFileName,
            ),
          ).writeAsStringSync(
            'state: IDLE\n'
            'issue: null\n'
            'ape:\n'
            '  name: dewey\n'
            '  state: create_or_select\n',
          );

          final cmd = ApePromptCommand(
            ApePromptInput(name: 'dewey', workingDirectory: gitTmpDir.path),
          );
          final result = await cmd.execute();

          expect(result.subState, equals('create_or_select'));
          expect(
            result.prompt,
            contains('FOCUS: Issue formulation. Create or select.'),
          );
          expect(result.prompt, contains('# --- inquiry-context ---'));
          expect(
            result.prompt,
            contains(
              'IDLE owns that fast-path routing contract: triage_objective=create_or_select, deterministic_skill=issue-create, allowed_commands=gh issue list, gh issue view, gh issue create, gh issue edit.',
            ),
          );
          expect(result.prompt, contains('triage_objective: create_or_select'));
          expect(result.prompt, contains('deterministic_skill: issue-create'));
          expect(
            result.prompt,
            contains(
              'allowed_commands: gh issue list, gh issue view, gh issue create, gh issue edit',
            ),
          );
          expectOperationalContractBetween(
            result.prompt,
            identityFragment: 'FOCUS: Issue formulation. Create or select.',
            contractFragment:
                'IDLE owns that fast-path routing contract: triage_objective=create_or_select',
          );
          expectExplicitContextAfter(
            result.prompt,
            'FOCUS: Issue formulation. Create or select.',
          );
        },
      );

      test(
        'dewey search_existing prompt keeps GitHub procedure in the IDLE contract',
        () async {
          File(
            p.join(
              gitTmpDir.path,
              'cleanrooms',
              '152-test-branch',
              kStateFileName,
            ),
          ).writeAsStringSync(
            'state: IDLE\n'
            'issue: null\n'
            'ape:\n'
            '  name: dewey\n'
            '  state: search_existing\n',
          );

          final cmd = ApePromptCommand(
            ApePromptInput(name: 'dewey', workingDirectory: gitTmpDir.path),
          );
          final result = await cmd.execute();

          expect(result.subState, equals('search_existing'));
          expect(
            result.prompt,
            contains('FOCUS: Deduplication. Search before creating.'),
          );
          expect(
            result.prompt,
            isNot(
              contains(
                'Use: `gh issue list --search "<keywords>"` to find existing issues.',
              ),
            ),
          );
          expect(
            result.prompt,
            contains(
              'IDLE owns that fast-path routing contract: triage_objective=create_or_select, deterministic_skill=issue-create, allowed_commands=gh issue list, gh issue view, gh issue create, gh issue edit.',
            ),
          );
          final promptIndex = result.prompt.indexOf(
            'FOCUS: Deduplication. Search before creating.',
          );
          final contractIndex = result.prompt.indexOf(
            '## Phase-Owned Operational Contract',
          );
          final detailIndex = result.prompt.indexOf(
            'IDLE owns that fast-path routing contract: triage_objective=create_or_select',
          );

          expect(promptIndex, greaterThanOrEqualTo(0));
          expect(contractIndex, greaterThan(promptIndex));
          expect(detailIndex, greaterThan(contractIndex));
        },
      );

      test('darwin prompt includes cycle artifact contract in assembled prompt', () async {
        File(
          p.join(
            gitTmpDir.path,
            'cleanrooms',
            '152-test-branch',
            kStateFileName,
          ),
        ).writeAsStringSync('state: EVOLUTION\nissue: "152"\n');

        final cmd = ApePromptCommand(
          ApePromptInput(
            name: 'darwin',
            subState: 'observe',
            workingDirectory: gitTmpDir.path,
          ),
        );
        final result = await cmd.execute();

        expect(result.prompt, contains('diagnosis.md'));
        expect(result.prompt, contains('FOCUS: Observation.'));
        expect(
          result.prompt,
          contains(
            'EVOLUTION owns the repository procedure for issue search/comment/create and metrics collection.',
          ),
        );
        expect(result.prompt, contains('# --- inquiry-context ---'));
        expect(
          result.prompt,
          contains('analyze_dir: cleanrooms/152-test-branch/analyze/'),
        );
        expect(
          result.prompt,
          contains('plan_file: cleanrooms/152-test-branch/plan.md'),
        );
        expect(
          result.prompt,
          contains(
            'retrospective_file: cleanrooms/152-test-branch/retrospective.md',
          ),
        );
        expect(
          result.prompt,
          contains('mutations_file: cleanrooms/152-test-branch/mutations.md'),
        );
        expect(
          result.prompt,
          contains('state_file: cleanrooms/152-test-branch/.iq.state.yaml'),
        );
        expect(
          result.prompt,
          contains('metrics_snapshot_file: .inquiry/metrics_snapshot.yaml'),
        );
        expect(result.prompt, contains('metrics_file: .inquiry/metrics.yaml'));
        expect(
          result.prompt,
          contains('observability_policy: evolution-audit'),
        );
        expect(
          result.prompt,
          contains(
            'execution_trace_surface: cleanrooms/152-test-branch/run_trace.yaml',
          ),
        );
        expect(
          result.prompt,
          contains(
            "trace_targets: ['transition', 'sensor_run', 'block', 'retry', 'phase_timing']",
          ),
        );
        expect(
          result.prompt,
          contains('eval_policy: harness-evolution-minimum'),
        );
        expect(
          result.prompt,
          contains(
            "eval_targets: ['task_contract_failure', 'evidence_discipline_failure', 'handoff_authority_failure', 'sensor_gate_failure', 'observability_failure']",
          ),
        );
        expect(
          result.prompt,
          contains(
            "grader_stack: ['structure_grader', 'trace_grader', 'artifact_consistency_grader', 'human_audit_grader']",
          ),
        );
        expect(
          result.prompt,
          contains(
            'eval_authority_rule: trace and artifact graders outrank narrative retrospection when classifying repeated harness failures',
          ),
        );
        expect(
          result.prompt,
          contains('output_dir: cleanrooms/152-test-branch/'),
        );
        expectExplicitContextAfter(result.prompt, 'FOCUS: Observation.');
      });

      test('no context injected when not in a git repo', () async {
        // A fresh directory with no git repo → no cycle resolves.
        final nonGitDir = Directory.systemTemp.createTempSync('ape_nogit_');
        addTearDown(() => nonGitDir.deleteSync(recursive: true));
        final apesDir = Directory(p.join(nonGitDir.path, 'assets', 'apes'));
        apesDir.createSync(recursive: true);
        File(
          'assets/apes/dewey.yaml',
        ).copySync(p.join(apesDir.path, 'dewey.yaml'));
        final statesDir = Directory(
          p.join(nonGitDir.path, 'assets', 'fsm', 'states'),
        );
        statesDir.createSync(recursive: true);
        for (final name in [
          'idle',
          'analyze',
          'plan',
          'execute',
          'end',
          'evolution',
        ]) {
          File(
            'assets/fsm/states/$name.yaml',
          ).copySync(p.join(statesDir.path, '$name.yaml'));
        }

        // Outside any git repo, no cycle resolves → derived IDLE (dewey).
        final cmd = ApePromptCommand(
          ApePromptInput(name: 'dewey', workingDirectory: nonGitDir.path),
        );
        final result = await cmd.execute();

        expect(result.prompt, isNot(contains('# --- inquiry-context ---')));
      });
    });
  });
}

void _initGitRepo(String root, {required String branch}) {
  void git(List<String> args) {
    final result = Process.runSync('git', args, workingDirectory: root);
    if (result.exitCode != 0) {
      throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
    }
  }

  git(['init']);
  git(['config', 'user.email', 'test@test.com']);
  git(['config', 'user.name', 'Test']);
  File(p.join(root, '.gitkeep')).writeAsStringSync('');
  git(['add', '.']);
  git(['commit', '-m', 'init']);
  git(['checkout', '-b', branch]);
}
