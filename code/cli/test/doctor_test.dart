import 'dart:io';

import 'package:inquiry_cli/assets.dart';
import 'package:inquiry_cli/modules/global/commands/doctor.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Mock filesystem for testing doctor host checks.
class MockFileSystemOps implements FileSystemOps {
  final Map<String, bool> _files = {};
  final Map<String, bool> _dirs = {};
  final Map<String, String> _contents = {};
  String _home = '/home/testuser';

  void setFileExists(String path, bool exists) => _files[path] = exists;
  void setDirectoryExists(String path, bool exists) => _dirs[path] = exists;
  void setHome(String home) => _home = home;
  void setFileContents(String path, String content) {
    _contents[path] = content;
    _files[path] = true;
  }

  @override
  bool fileExists(String path) => _files[path] ?? false;

  @override
  bool directoryExists(String path) => _dirs[path] ?? false;

  @override
  String homeDirectory() => _home;

  @override
  String? readFile(String path) => _contents[path];
}

void main() {
  group('InquiryDoctorChecks', () {
    // Helper to create a fake ProcessRunner
    ProcessRunner fakeRunner({
      bool gitFails = false,
      bool ghFails = false,
      bool ghAuthFails = false,
      Map<String, int?>? ollamaCtx,
    }) {
      return (
        String executable,
        List<String> arguments, {
        String? workingDirectory,
      }) async {
        // ollama show <model> --modelfile
        if (executable == 'ollama' && arguments.contains('show')) {
          final model = arguments.firstWhere(
            (a) => a != 'show' && a != '--modelfile',
            orElse: () => '',
          );
          final ctx = ollamaCtx?[model];
          if (ctx == null) {
            // No num_ctx PARAMETER → Ollama default (4096)
            return ProcessResult(0, 0, 'FROM $model\n', '');
          }
          return ProcessResult(
            0,
            0,
            'FROM $model\nPARAMETER num_ctx $ctx\n',
            '',
          );
        }

        // git --version
        if (executable == 'git' && arguments.contains('--version')) {
          if (gitFails) {
            return ProcessResult(1, 1, '', 'git: command not found');
          }
          return ProcessResult(0, 0, 'git version 2.43.0', '');
        }

        // gh auth status
        if (executable == 'gh' && arguments.contains('auth')) {
          if (ghAuthFails) {
            return ProcessResult(
              1,
              1,
              '',
              'You are not logged into any GitHub hosts.',
            );
          }
          return ProcessResult(
            0,
            0,
            'Logged in to github.com as user (oauth_token)',
            '',
          );
        }

        // gh --version
        if (executable == 'gh' && arguments.contains('--version')) {
          if (ghFails) {
            return ProcessResult(1, 1, '', 'gh: command not found');
          }
          return ProcessResult(0, 0, 'gh version 2.45.0 (2024-03-01)', '');
        }

        // Default: success
        return ProcessResult(0, 0, 'v1.0.0', '');
      };
    }

    // Constants for test paths
    const workingDir = '/repo/current';
    const homeDir = '/home/testuser';

    /// Creates a mock FS where `.inquiry/` exists and OpenCode is installed
    /// GLOBALLY (agent + skills) — the default active host (#280).
    MockFileSystemOps allPassFs(String wd, String home, List<String> skills) {
      final fs = MockFileSystemOps()..setHome(home);
      fs.setDirectoryExists('.inquiry', true);
      // The host tool itself is present: `iq host get` only deploys where the
      // host exists, so a deployed fixture implies an installed one (#300).
      fs.setDirectoryExists(p.join(home, '.config', 'opencode'), true);
      fs.setFileExists(
        p.join(home, '.config', 'opencode', 'agent', 'inquiry.md'),
        true,
      );
      for (final skill in skills) {
        fs.setFileExists(
          p.join(home, '.config', 'opencode', 'skills', skill, 'SKILL.md'),
          true,
        );
      }
      return fs;
    }

    /// Creates a temp Assets directory with the given skill names.
    late Directory tempDir;
    late Assets testAssets;
    final testSkills = [
      'doc-read',
      'doc-write',
      'inquiry-install',
      'kritik',
      'legion',
      'research',
      'issue-create',
      'inquiry-start',
      'inquiry-end',
    ];

    /// The lifecycle skills that moved to MACSS. `iq host get` no longer
    /// installs them, so doctor must not expect them either.
    const migratedSkills = [
      'iq-analyze',
      'iq-plan',
      'iq-execute',
      'iq-specification',
    ];

    /// Everything `iq host get` installs: the asset-tree skills, and only those.
    final deployedSkills = [...testSkills];

    Assets seedAssets(Directory root, {required List<String> apes}) {
      final skillsDir = Directory(p.join(root.path, 'assets', 'skills'));
      for (final skill in testSkills) {
        final skillDir = Directory(p.join(skillsDir.path, skill));
        skillDir.createSync(recursive: true);
        File(
          p.join(skillDir.path, 'SKILL.md'),
        ).writeAsStringSync('---\nname: $skill\n---');
      }

      final agentsDir = Directory(p.join(root.path, 'assets', 'agents'));
      agentsDir.createSync(recursive: true);
      File(
        p.join(agentsDir.path, 'inquiry.agent.md'),
      ).writeAsStringSync('# Agent');

      final apesDir = Directory(p.join(root.path, 'assets', 'apes'));
      apesDir.createSync(recursive: true);
      for (final ape in apes) {
        File(
          p.join(apesDir.path, '$ape.yaml'),
        ).writeAsStringSync('name: $ape\n');
      }

      final statesDir = Directory(p.join(root.path, 'assets', 'fsm', 'states'));
      statesDir.createSync(recursive: true);
      for (final state in [
        'idle',
        'analyze',
        'plan',
        'execute',
        'end',
        'evolution',
      ]) {
        File(
          p.join(statesDir.path, '$state.yaml'),
        ).writeAsStringSync('name: $state\ninstructions: "test"\n');
      }

      final fsmDir = Directory(p.join(root.path, 'assets', 'fsm'));
      File(
        p.join(fsmDir.path, 'transition_contract.yaml'),
      ).writeAsStringSync('metadata:\n  version: "1.0.0"\n');

      return Assets(root: root.path);
    }

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('doctor_test_');
      testAssets = seedAssets(
        tempDir,
        apes: ['socrates', 'dewey', 'descartes', 'ada', 'darwin'],
      );
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    InquiryDoctorChecks makeChecks({
      ProcessRunner? runProcess,
      String version = '0.0.9',
      MockFileSystemOps? fs,
      Assets? assets,
      String? wd,
    }) {
      final resolvedWd = wd ?? workingDir;
      return InquiryDoctorChecks(
        runProcess: runProcess ?? fakeRunner(),
        inquiryVersionOverride: version,
        fileSystemOps: fs ?? allPassFs(resolvedWd, homeDir, deployedSkills),
        assets: assets ?? testAssets,
      );
    }

    test('checkInquiryVersion reports the injected version', () async {
      final checks = makeChecks(version: '0.0.10');
      final result = await checks.checkInquiryVersion();

      expect(result.status, CliCheckStatus.ok);
      expect(result.message, '0.0.10');
    });

    test('checkAssets passes when everything is present', () async {
      final checks = makeChecks();
      final result = await checks.checkAssets();

      expect(result.status, CliCheckStatus.ok);
    });

    test(
      'checkAssets reports missing dewey when bundled APEs omit it',
      () async {
        final customDir = Directory.systemTemp.createTempSync(
          'doctor_missing_dewey_',
        );
        addTearDown(() => customDir.deleteSync(recursive: true));

        final checks = makeChecks(
          assets: seedAssets(
            customDir,
            apes: ['socrates', 'descartes', 'ada', 'darwin'],
          ),
        );
        final result = await checks.checkAssets();

        expect(result.status, CliCheckStatus.error);
        expect(result.message, contains('apes/dewey.yaml'));
        expect(result.message, isNot(contains('apes/socrates-idle.yaml')));
      },
    );

    test(
      'checkAssets does not require socrates-idle when dewey is present',
      () async {
        final customDir = Directory.systemTemp.createTempSync(
          'doctor_without_socrates_idle_',
        );
        addTearDown(() => customDir.deleteSync(recursive: true));

        final checks = makeChecks(
          assets: seedAssets(
            customDir,
            apes: ['socrates', 'dewey', 'descartes', 'ada', 'darwin'],
          ),
        );
        final result = await checks.checkAssets();

        expect(result.message, isNot(contains('apes/socrates-idle.yaml')));
        expect(result.status, CliCheckStatus.ok);
      },
    );

    // `iq upgrade --apply` no-ops ("Already on the latest version") whenever
    // the installed binary already matches the latest release tag, which
    // says nothing about whether assets/ on disk are intact. Missing assets
    // while the binary is already current is exactly the case where telling
    // someone to run upgrade sends them to a command that will do nothing.
    test(
      'checkAssets does not point at upgrade to restore missing assets, '
      'since upgrade is a no-op once the binary is already current',
      () async {
        final customDir = Directory.systemTemp.createTempSync(
          'doctor_missing_assets_remedy_',
        );
        addTearDown(() => customDir.deleteSync(recursive: true));

        final checks = makeChecks(
          assets: seedAssets(
            customDir,
            apes: ['socrates', 'descartes', 'ada', 'darwin'],
          ),
        );
        final result = await checks.checkAssets();

        expect(result.status, CliCheckStatus.error);
        expect(
          result.message,
          isNot(contains("Run 'iq upgrade")),
          reason:
              'must not tell the user to run a command that will do '
              'nothing once the binary is already current',
        );
        expect(
          result.message,
          contains('install.ps1'),
          reason:
              'reinstalling from the site installer is what actually '
              're-extracts assets/, unlike a no-op upgrade',
        );
      },
    );

    test('checkGit reports error when git is missing', () async {
      final checks = makeChecks(runProcess: fakeRunner(gitFails: true));
      final result = await checks.checkGit();

      expect(result.status, CliCheckStatus.error);
    });

    test('checkGh reports error when gh is missing', () async {
      final checks = makeChecks(runProcess: fakeRunner(ghFails: true));
      final result = await checks.checkGh();

      expect(result.status, CliCheckStatus.error);
    });

    test('checkGhAuth reports error when gh auth fails', () async {
      final checks = makeChecks(runProcess: fakeRunner(ghAuthFails: true));
      final result = await checks.checkGhAuth();

      expect(result.status, CliCheckStatus.error);
    });

    test('checkInit reports error when .inquiry/ is missing', () async {
      final fs = MockFileSystemOps()..setHome(homeDir);
      final checks = makeChecks(fs: fs);
      final result = await checks.checkInit();

      expect(result.status, CliCheckStatus.error);
      expect(result.message, contains("Run 'inquiry init'"));
    });

    group('Host verification', () {
      test('Scenario A: active host (opencode) deployed → ok', () async {
        final checks = makeChecks();
        final result = await checks.checkHost(
          checks.activeAdapters.firstWhere((a) => a.name == 'opencode'),
        );

        expect(result.status, CliCheckStatus.ok);
        expect(result.message, 'agent deployed');

        final claude = await checks.checkHost(
          checks.activeAdapters.firstWhere((a) => a.name == 'claude'),
        );
        expect(claude.status, CliCheckStatus.ok);
        expect(claude.message, 'not installed');

        final anyActive = await checks.checkAnyHostActive();
        expect(anyActive.status, CliCheckStatus.ok);
      });

      test(
        'Scenario B1: host installed but nothing deployed → error',
        () async {
          final fs = MockFileSystemOps()..setHome(homeDir);
          fs.setDirectoryExists('.inquiry', true);
          // OpenCode is on the machine; inquiry was never deployed into it.
          fs.setDirectoryExists(p.join(homeDir, '.config', 'opencode'), true);

          final checks = makeChecks(fs: fs);
          final anyActive = await checks.checkAnyHostActive();

          expect(anyActive.status, CliCheckStatus.error);
          expect(anyActive.message, contains("Run 'iq host get --apply'"));
        },
      );

      test('Scenario B2: no host installed → not a failure', () async {
        // A machine may carry the CLI and no AI assistant at all. Nothing to
        // deploy into is a legitimate state, not a missing step (#300).
        final fs = MockFileSystemOps()..setHome(homeDir);
        fs.setDirectoryExists('.inquiry', true);

        final checks = makeChecks(fs: fs);
        final anyActive = await checks.checkAnyHostActive();

        expect(anyActive.status, CliCheckStatus.ok);
        expect(
          anyActive.message,
          contains('no AI coding host installed on this machine'),
        );
      });

      test('Scenario C: no .inquiry/ directory → error', () async {
        final fs = MockFileSystemOps()..setHome(homeDir);
        // .inquiry does NOT exist, hosts do NOT exist

        final checks = makeChecks(fs: fs);
        final initCheck = await checks.checkInit();

        expect(initCheck.status, CliCheckStatus.error);

        // The hosts are simply absent from this machine, which is not what
        // this scenario is about.
        final anyActive = await checks.checkAnyHostActive();
        expect(
          anyActive.message,
          contains('no AI coding host installed on this machine'),
        );
      });

      test(
        'Scenario D: partial deployment → error, names the missing skill',
        () async {
          final fs = MockFileSystemOps()..setHome(homeDir);
          fs.setDirectoryExists('.inquiry', true);
          fs.setDirectoryExists(p.join(homeDir, '.config', 'opencode'), true);
          // OpenCode global agent present
          fs.setFileExists(
            p.join(homeDir, '.config', 'opencode', 'agent', 'inquiry.md'),
            true,
          );
          // Deploy everything except issue-create (global skills).
          for (final skill in deployedSkills.where(
            (s) => s != 'issue-create',
          )) {
            fs.setFileExists(
              p.join(
                homeDir,
                '.config',
                'opencode',
                'skills',
                skill,
                'SKILL.md',
              ),
              true,
            );
          }
          // issue-create is MISSING

          final checks = makeChecks(fs: fs);
          final opencode = checks.verifyHost(
            checks.activeAdapters.firstWhere((a) => a.name == 'opencode'),
          );
          expect(opencode.active, isTrue);
          expect(opencode.agentExists, isTrue);
          expect(opencode.missingSkills, ['issue-create']);

          final result = await checks.checkHost(
            checks.activeAdapters.firstWhere((a) => a.name == 'opencode'),
          );
          expect(result.status, CliCheckStatus.error);
          expect(result.message, contains('missing skills: issue-create'));
          expect(
            result.message,
            contains("Run 'iq host get --host opencode --apply'"),
          );
        },
      );

      test('HostCheck.toJson() includes all fields', () {
        final check = HostCheck(
          hostName: 'copilot',
          agentExists: true,
          missingSkills: ['doc-read'],
          totalSkills: 9,
        );

        final json = check.toJson();
        expect(json['hostName'], 'copilot');
        expect(json['agentExists'], true);
        expect(json['missingSkills'], ['doc-read']);
        expect(json['totalSkills'], 9);
      });

      test(
        'HostCheck.passed is true when agent exists and no missing skills',
        () {
          final passing = HostCheck(
            hostName: 'copilot',
            agentExists: true,
            missingSkills: [],
            totalSkills: 9,
          );
          expect(passing.passed, isTrue);

          final failing = HostCheck(
            hostName: 'copilot',
            agentExists: false,
            missingSkills: ['x'],
            totalSkills: 1,
          );
          expect(failing.passed, isFalse);
        },
      );

      // ─── E3: repo-scoped agent tests ───────────────────────────────────────

      test(
        'doctor passes when inquiry.agent.md is in .github/agents/',
        () async {
          final fs = allPassFs(workingDir, homeDir, deployedSkills);
          final checks = makeChecks(fs: fs);

          final opencode = checks.verifyHost(
            checks.activeAdapters.firstWhere((a) => a.name == 'opencode'),
          );
          expect(opencode.agentExists, isTrue);
        },
      );

      test(
        'doctor fails when inquiry.agent.md is NOT in .github/agents/',
        () async {
          final fs = MockFileSystemOps()..setHome(homeDir);
          fs.setDirectoryExists('.inquiry', true);
          // Agent absent — no file set

          final checks = makeChecks(fs: fs);
          final opencode = checks.verifyHost(
            checks.activeAdapters.firstWhere((a) => a.name == 'opencode'),
          );
          expect(opencode.agentExists, isFalse);
        },
      );

      test('doctor ignores agent at old path ~/.copilot/agents/', () async {
        final fs = MockFileSystemOps()..setHome(homeDir);
        fs.setDirectoryExists('.inquiry', true);
        // Agent at OLD global path (pre-0.5.0)
        fs.setFileExists(
          p.join(homeDir, '.copilot', 'agents', 'inquiry.agent.md'),
          true,
        );
        // NOT in new repo-scoped path

        final checks = makeChecks(fs: fs);
        final opencode = checks.verifyHost(
          checks.activeAdapters.firstWhere((a) => a.name == 'opencode'),
        );
        expect(
          opencode.agentExists,
          isFalse,
          reason: 'Old global path is no longer valid — must run iq init',
        );
      });

      test(
        'doctor remediation suggests host get when no host is deployed',
        () async {
          final fs = MockFileSystemOps()..setHome(homeDir);
          fs.setDirectoryExists('.inquiry', true);
          // A host exists to deploy into; no agent, no skills → no active host.
          fs.setDirectoryExists(p.join(homeDir, '.claude'), true);

          final checks = makeChecks(fs: fs);
          final anyActive = await checks.checkAnyHostActive();

          expect(anyActive.status, CliCheckStatus.error);
          expect(anyActive.message, contains("Run 'iq host get --apply'"));
          expect(anyActive.message, isNot(contains("'inquiry target get'")));
        },
      );

      test(
        'Scenario E: OpenCode active (global), Claude inactive → ok',
        () async {
          final fs = MockFileSystemOps()..setHome(homeDir);
          fs.setDirectoryExists('.inquiry', true);
          // Both hosts are on the machine; only OpenCode was deployed into. This
          // is what distinguishes "inactive" from "not installed" (#300).
          fs.setDirectoryExists(p.join(homeDir, '.config', 'opencode'), true);
          fs.setDirectoryExists(p.join(homeDir, '.claude'), true);
          // OpenCode installed globally: agent + skills (#280).
          fs.setFileExists(
            p.join(homeDir, '.config', 'opencode', 'agent', 'inquiry.md'),
            true,
          );
          for (final skill in deployedSkills) {
            fs.setFileExists(
              p.join(
                homeDir,
                '.config',
                'opencode',
                'skills',
                skill,
                'SKILL.md',
              ),
              true,
            );
          }

          final checks = makeChecks(fs: fs);
          final opencode = await checks.checkHost(
            checks.activeAdapters.firstWhere((a) => a.name == 'opencode'),
          );
          expect(opencode.status, CliCheckStatus.ok);
          expect(opencode.message, 'agent deployed');

          final claude = await checks.checkHost(
            checks.activeAdapters.firstWhere((a) => a.name == 'claude'),
          );
          expect(
            claude.message,
            'not deployed (inactive)',
            reason: 'Claude not deployed → inactive, not a failure',
          );

          final anyActive = await checks.checkAnyHostActive();
          expect(anyActive.status, CliCheckStatus.ok);
        },
      );

      test('empty skills asset dir → nothing is expected', () async {
        // Expectations come from the asset tree alone. An asset tree shipping no
        // skills expects none, so a host carrying unrelated ones still passes.
        final fs = allPassFs(workingDir, homeDir, migratedSkills);
        final emptyTempDir = Directory.systemTemp.createTempSync(
          'empty_assets_',
        );
        Directory(
          p.join(emptyTempDir.path, 'assets', 'skills'),
        ).createSync(recursive: true);
        final emptyAssets = Assets(root: emptyTempDir.path);

        final checks = makeChecks(fs: fs, assets: emptyAssets);
        final opencode = checks.verifyHost(
          checks.activeAdapters.firstWhere((a) => a.name == 'opencode'),
        );

        expect(opencode.totalSkills, 0);
        expect(opencode.missingSkills, isEmpty);
        expect(opencode.agentExists, isTrue);
        expect(opencode.passed, isTrue);

        emptyTempDir.deleteSync(recursive: true);
      });
    });

    group('OpenCode/Ollama context check (#259)', () {
      const jsonc = '''
{
  // local Ollama provider
  "\$schema": "https://opencode.ai/config.json",
  "provider": { "ollama": { "models": {
    "qwen3-coder:30b": {},
    "qwen3-coder:30b-16k": {}
  } } }
}
''';

      // Filesystem where OpenCode is the active/deployed host (global, #280).
      MockFileSystemOps opencodeActiveFs() {
        final fs = MockFileSystemOps()..setHome(homeDir);
        fs.setDirectoryExists('.inquiry', true);
        fs.setFileExists(
          p.join(homeDir, '.config', 'opencode', 'agent', 'inquiry.md'),
          true,
        );
        for (final s in deployedSkills) {
          fs.setFileExists(
            p.join(homeDir, '.config', 'opencode', 'skills', s, 'SKILL.md'),
            true,
          );
        }
        fs.setFileContents(
          p.join(homeDir, '.config', 'opencode', 'opencode.jsonc'),
          jsonc,
        );
        return fs;
      }

      test(
        'FAILS when a configured Ollama model defaults to num_ctx 4096',
        () async {
          // 30b-16k is fine; 30b is omitted → fakeRunner emits no num_ctx → 4096.
          final checks = makeChecks(
            fs: opencodeActiveFs(),
            runProcess: fakeRunner(ollamaCtx: {'qwen3-coder:30b-16k': 16384}),
          );
          final result = await checks.checkOllamaContext();

          expect(result.status, CliCheckStatus.error);
          expect(result.message, contains('qwen3-coder:30b'));
          expect(result.message, contains('4096'));
          // the adequate model must NOT be flagged
          expect(result.message, isNot(contains('30b-16k (num_ctx')));
        },
      );

      test('PASSES when all Ollama models have num_ctx >= 16384', () async {
        final checks = makeChecks(
          fs: opencodeActiveFs(),
          runProcess: fakeRunner(
            ollamaCtx: {'qwen3-coder:30b': 16384, 'qwen3-coder:30b-16k': 32768},
          ),
        );
        final result = await checks.checkOllamaContext();

        expect(result.status, CliCheckStatus.ok);
      });

      test('is not applicable when OpenCode is not the active host', () async {
        // Claude active; OpenCode inactive. A 4096 Ollama model must not fail.
        final fs = MockFileSystemOps()..setHome(homeDir);
        fs.setDirectoryExists('.inquiry', true);
        fs.setFileExists(
          p.join(homeDir, '.claude', 'agents', 'inquiry.md'),
          true,
        );
        for (final s in deployedSkills) {
          fs.setFileExists(
            p.join(homeDir, '.claude', 'skills', s, 'SKILL.md'),
            true,
          );
        }
        fs.setFileContents(
          p.join(homeDir, '.config', 'opencode', 'opencode.jsonc'),
          jsonc,
        );
        final checks = makeChecks(
          fs: fs,
          runProcess: fakeRunner(ollamaCtx: {}),
        );
        final result = await checks.checkOllamaContext();

        expect(result.status, CliCheckStatus.ok);
        expect(result.message, contains('not applicable'));
      });
    });

    // The lifecycle skills moved to MACSS, which installs them with
    // `macss skill deploy`. Doctor must expect exactly what this deployer
    // installs — the asset tree — or every host reports unhealthy for a
    // deployment inquiry no longer performs.
    group('migrated lifecycle skills', () {
      test(
        'are not expected: the asset-tree skills alone are healthy',
        () async {
          final checks = makeChecks(
            fs: allPassFs(workingDir, homeDir, testSkills),
          );

          final opencode = checks.verifyHost(
            checks.activeAdapters.firstWhere((a) => a.name == 'opencode'),
          );

          expect(opencode.missingSkills, isEmpty);
          expect(opencode.totalSkills, testSkills.length);
          expect(opencode.passed, isTrue);
        },
      );

      test('their absence is never reported as missing', () async {
        final checks = makeChecks(
          fs: allPassFs(workingDir, homeDir, testSkills),
        );

        for (final adapter in checks.activeAdapters) {
          final host = checks.verifyHost(adapter);
          for (final skill in migratedSkills) {
            expect(host.missingSkills, isNot(contains(skill)));
          }
        }
      });
    });
  });
}
