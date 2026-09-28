import 'dart:io';

import 'package:inquiry_cli/modules/ape/commands/transition.dart';
import 'package:inquiry_cli/modules/ape/inquiry_state.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmpDir;

  const branch = '145-test-branch';

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('ape_transition_test_');
    Directory(p.join(tmpDir.path, '.inquiry')).createSync(recursive: true);
    _initGitRepo(tmpDir.path, branch: branch);

    // Copy APE YAML assets
    final apesDir = Directory(p.join(tmpDir.path, 'assets', 'apes'));
    apesDir.createSync(recursive: true);
    for (final name in ['socrates', 'dewey', 'descartes', 'ada', 'darwin']) {
      File(
        'assets/apes/$name.yaml',
      ).copySync(p.join(apesDir.path, '$name.yaml'));
    }
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  void writeState({
    required String state,
    String? issue,
    String? apeName,
    String? apeState,
  }) {
    final buf = StringBuffer();
    buf.writeln('state: $state');
    buf.writeln(issue != null ? 'issue: "$issue"' : 'issue: null');
    if (apeName != null) {
      buf.writeln('ape:');
      buf.writeln('  name: $apeName');
      buf.writeln('  state: ${apeState ?? "null"}');
    } else {
      buf.writeln('ape: null');
    }
    File(p.join(tmpDir.path, 'cleanrooms', branch, kStateFileName))
      ..createSync(recursive: true)
      ..writeAsStringSync(buf.toString());
  }

  group('ApeTransitionCommand', () {
    group('successful transitions', () {
      test('socrates clarification --next--> assumptions', () async {
        writeState(
          state: 'ANALYZE',
          issue: '145',
          apeName: 'socrates',
          apeState: 'clarification',
        );

        final cmd = ApeTransitionCommand(
          ApeTransitionInput(event: 'next', workingDirectory: tmpDir.path),
        );
        final result = await cmd.execute();

        expect(result.apeName, equals('socrates'));
        expect(result.from, equals('clarification'));
        expect(result.event, equals('next'));
        expect(result.to, equals('assumptions'));
      });

      test('persists new ape state to state.yaml', () async {
        writeState(
          state: 'ANALYZE',
          issue: '145',
          apeName: 'socrates',
          apeState: 'clarification',
        );

        final cmd = ApeTransitionCommand(
          ApeTransitionInput(event: 'next', workingDirectory: tmpDir.path),
        );
        await cmd.execute();

        // Verify persisted
        final content = File(
          p.join(tmpDir.path, 'cleanrooms', branch, kStateFileName),
        ).readAsStringSync();
        expect(content, contains('state: assumptions'));
        // Main FSM state preserved
        expect(content, contains('state: ANALYZE'));
        expect(content, contains('issue: "145"'));
      });

      test('ada frame_intent --next--> locate_control_surface', () async {
        writeState(
          state: 'EXECUTE',
          issue: '145',
          apeName: 'ada',
          apeState: 'frame_intent',
        );

        final cmd = ApeTransitionCommand(
          ApeTransitionInput(event: 'next', workingDirectory: tmpDir.path),
        );
        final result = await cmd.execute();

        expect(result.from, equals('frame_intent'));
        expect(result.to, equals('locate_control_surface'));
      });

      test('ada manifesto_review --rewrite--> compose_change', () async {
        writeState(
          state: 'EXECUTE',
          issue: '145',
          apeName: 'ada',
          apeState: 'manifesto_review',
        );

        final cmd = ApeTransitionCommand(
          ApeTransitionInput(event: 'rewrite', workingDirectory: tmpDir.path),
        );
        final result = await cmd.execute();

        expect(result.from, equals('manifesto_review'));
        expect(result.to, equals('compose_change'));
      });

      test(
        'ada manifesto_review --complete--> _DONE preserves outer FSM state',
        () async {
          writeState(
            state: 'EXECUTE',
            issue: '145',
            apeName: 'ada',
            apeState: 'manifesto_review',
          );

          final cmd = ApeTransitionCommand(
            ApeTransitionInput(
              event: 'complete',
              workingDirectory: tmpDir.path,
            ),
          );
          final result = await cmd.execute();

          expect(result.from, equals('manifesto_review'));
          expect(result.to, equals('_DONE'));

          final content = File(
            p.join(tmpDir.path, 'cleanrooms', branch, kStateFileName),
          ).readAsStringSync();
          expect(content, contains('state: EXECUTE'));
          expect(content, contains('issue: "145"'));
          expect(content, contains('name: ada'));
          expect(content, contains('state: _DONE'));
          expect(content, isNot(contains('issue: null')));
          expect(content, isNot(contains('state: IDLE')));
        },
      );

      test('dewey confirm --complete--> evaluate_scope', () async {
        writeState(state: 'IDLE', apeName: 'dewey', apeState: 'confirm');

        final cmd = ApeTransitionCommand(
          ApeTransitionInput(event: 'complete', workingDirectory: tmpDir.path),
        );
        final result = await cmd.execute();

        expect(result.apeName, equals('dewey'));
        expect(result.from, equals('confirm'));
        expect(result.event, equals('complete'));
        expect(result.to, equals('evaluate_scope'));
      });

      test('dewey search_existing --next--> create_or_select', () async {
        writeState(
          state: 'IDLE',
          apeName: 'dewey',
          apeState: 'search_existing',
        );

        final cmd = ApeTransitionCommand(
          ApeTransitionInput(event: 'next', workingDirectory: tmpDir.path),
        );
        final result = await cmd.execute();

        expect(result.apeName, equals('dewey'));
        expect(result.from, equals('search_existing'));
        expect(result.event, equals('next'));
        expect(result.to, equals('create_or_select'));
      });

      test('reaches _DONE sentinel', () async {
        writeState(
          state: 'ANALYZE',
          issue: '145',
          apeName: 'socrates',
          apeState: 'meta_reflection',
        );

        final cmd = ApeTransitionCommand(
          ApeTransitionInput(event: 'complete', workingDirectory: tmpDir.path),
        );
        final result = await cmd.execute();

        expect(result.to, equals('_DONE'));
      });

      test('descartes decomposition --next--> ordering', () async {
        writeState(
          state: 'PLAN',
          issue: '145',
          apeName: 'descartes',
          apeState: 'decomposition',
        );

        final cmd = ApeTransitionCommand(
          ApeTransitionInput(event: 'next', workingDirectory: tmpDir.path),
        );
        final result = await cmd.execute();

        expect(result.from, equals('decomposition'));
        expect(result.to, equals('ordering'));
      });

      test('back transition works', () async {
        writeState(
          state: 'ANALYZE',
          issue: '145',
          apeName: 'socrates',
          apeState: 'assumptions',
        );

        final cmd = ApeTransitionCommand(
          ApeTransitionInput(event: 'back', workingDirectory: tmpDir.path),
        );
        final result = await cmd.execute();

        expect(result.from, equals('assumptions'));
        expect(result.to, equals('clarification'));
      });
    });

    group('error cases', () {
      test(
        'throws CommandException MISSING_EVENT when event flag is null',
        () async {
          writeState(
            state: 'ANALYZE',
            issue: '145',
            apeName: 'socrates',
            apeState: 'clarification',
          );

          final cmd = ApeTransitionCommand(
            ApeTransitionInput(event: null, workingDirectory: tmpDir.path),
          );

          expect(
            () => cmd.execute(),
            throwsA(
              isA<CommandException>()
                  .having((e) => e.id, 'id', equals('missing-event'))
                  .having(
                    (e) => e.exitCode,
                    'exitCode',
                    equals(ExitCode.validationFailed),
                  ),
            ),
          );
        },
      );

      test('throws NO_ACTIVE_APE when no APE in state', () async {
        writeState(state: 'IDLE');

        final cmd = ApeTransitionCommand(
          ApeTransitionInput(event: 'next', workingDirectory: tmpDir.path),
        );

        expect(
          () => cmd.execute(),
          throwsA(
            isA<CommandException>()
                .having((e) => e.id, 'id', equals('no-active-ape'))
                .having(
                  (e) => e.exitCode,
                  'exitCode',
                  equals(ExitCode.conflict),
                ),
          ),
        );
      });

      test('throws APE_COMPLETED when ape state is _DONE', () async {
        writeState(
          state: 'ANALYZE',
          issue: '145',
          apeName: 'socrates',
          apeState: '_DONE',
        );

        final cmd = ApeTransitionCommand(
          ApeTransitionInput(event: 'next', workingDirectory: tmpDir.path),
        );

        expect(
          () => cmd.execute(),
          throwsA(
            isA<CommandException>()
                .having((e) => e.id, 'id', equals('ape-completed'))
                .having(
                  (e) => e.exitCode,
                  'exitCode',
                  equals(ExitCode.conflict),
                ),
          ),
        );
      });

      test('throws INVALID_APE_EVENT for unknown event', () async {
        writeState(
          state: 'ANALYZE',
          issue: '145',
          apeName: 'socrates',
          apeState: 'clarification',
        );

        final cmd = ApeTransitionCommand(
          ApeTransitionInput(event: 'explode', workingDirectory: tmpDir.path),
        );

        expect(
          () => cmd.execute(),
          throwsA(
            isA<CommandException>()
                .having((e) => e.id, 'id', equals('invalid-ape-event'))
                .having(
                  (e) => e.exitCode,
                  'exitCode',
                  equals(ExitCode.validationFailed),
                ),
          ),
        );
      });

      test('throws APE_NOT_FOUND when YAML missing', () async {
        // Delete socrates YAML
        File(
          p.join(tmpDir.path, 'assets', 'apes', 'socrates.yaml'),
        ).deleteSync();

        writeState(
          state: 'ANALYZE',
          issue: '145',
          apeName: 'socrates',
          apeState: 'clarification',
        );

        final cmd = ApeTransitionCommand(
          ApeTransitionInput(event: 'next', workingDirectory: tmpDir.path),
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

    group('output format', () {
      test('toJson includes all fields', () async {
        writeState(
          state: 'PLAN',
          issue: '145',
          apeName: 'descartes',
          apeState: 'decomposition',
        );

        final cmd = ApeTransitionCommand(
          ApeTransitionInput(event: 'next', workingDirectory: tmpDir.path),
        );
        final result = await cmd.execute();
        final json = result.toJson();

        expect(json['ape'], equals('descartes'));
        expect(json['from'], equals('decomposition'));
        expect(json['event'], equals('next'));
        expect(json['to'], equals('ordering'));
      });

      test('toText returns readable string', () async {
        writeState(
          state: 'EXECUTE',
          issue: '145',
          apeName: 'ada',
          apeState: 'frame_intent',
        );

        final cmd = ApeTransitionCommand(
          ApeTransitionInput(event: 'next', workingDirectory: tmpDir.path),
        );
        final result = await cmd.execute();

        expect(
          result.toText(),
          equals('ada: frame_intent --next--> locate_control_surface'),
        );
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
