/// `iq implementation start --issue <N>` — one command that takes a published
/// issue from "nothing" to a ready ANALYZE cycle.
///
/// It owns the whole mechanical bootstrap that `assets/instructions/
/// inquiry-start.md` used to hand to the LLM step by step (derive slug, create
/// the branch, scaffold the cleanroom, transition): a mechanical process is an
/// `iq` command, not an instruction. Concretely it:
///
///   1. resolves the git project root (auto-runs `init` if the workspace is missing),
///   2. reads the issue title from GitHub (`gh issue view`),
///   3. derives the `<NNN>-<slug>` branch and checks it out (creating it if new),
///   4. fires the `start_analyze` transition, whose existing `open_analysis_context`
///      effect scaffolds `cleanrooms/<branch>/analyze/`.
///
/// Its errors are exemplary (AC2): every failure states what went wrong and how
/// to fix it, with a concrete example. Its happy path does NOT print a "next
/// step" — that would bias the user and make the command flow-aware.
library;

import 'dart:convert';
import 'dart:io';

import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:path/path.dart' as p;

import '../../../assets.dart';
import '../../../src/git_utils.dart';
import '../../fsm/commands/transition.dart';
import '../../global/commands/init.dart';
import '../branch_name.dart';

typedef GitCommandRunner =
    ProcessResult Function(String workingDirectory, List<String> arguments);

/// The title and state of a GitHub issue, or `null` when it cannot be read.
typedef IssueInfoProvider =
    ({String title, String state})? Function(
      String issue,
      String workingDirectory,
    );

/// Runs the `start_analyze` transition and reports success + message.
typedef StartAnalyzeRunner =
    Future<({bool ok, String message})> Function({
      required String issue,
      required String workingDirectory,
      Assets? assets,
    });

// ─── Input ──────────────────────────────────────────────────────────────────

class ImplementationStartInput extends Input {
  final String issue;
  final String workingDirectory;

  ImplementationStartInput({
    required this.issue,
    required this.workingDirectory,
  });

  static final CliContract contract = CliContract(
    options: [
      CliParam.string(
        'issue',
        abbr: null,
        required: true,
        repeatable: false,
        defaultValue: null,
        description: 'The GitHub issue number to implement (e.g. --issue 40)',
      ),
    ],
  );

  factory ImplementationStartInput.fromCliRequest(CliRequest req) =>
      ImplementationStartInput(
        issue: (req.flagString('issue') ?? '').trim(),
        workingDirectory: Directory.current.path,
      );

  @override
  Map<String, dynamic> toJson() => {
    'issue': issue,
    'workingDirectory': workingDirectory,
  };
}

// ─── Output ─────────────────────────────────────────────────────────────────

class ImplementationStartOutput extends Output {
  final String issue;
  final String branch;
  final String cleanroom;
  final bool branchCreated;
  final bool initialized;

  ImplementationStartOutput({
    required this.issue,
    required this.branch,
    required this.cleanroom,
    required this.branchCreated,
    required this.initialized,
  });

  @override
  Map<String, dynamic> toJson() => {
    'issue': issue,
    'branch': branch,
    'cleanroom': cleanroom,
    'branch_created': branchCreated,
    'initialized': initialized,
  };

  @override
  int get exitCode => ExitCode.ok;

  @override
  String? toText() {
    final buffer = StringBuffer();
    if (initialized) {
      buffer.writeln('Initialized Inquiry workspace (.inquiry/).');
    }
    buffer.writeln('Implementation started for issue #$issue:');
    buffer.writeln(
      '  branch:    $branch ${branchCreated ? '(created)' : '(existing)'}',
    );
    buffer.writeln('  cleanroom: $cleanroom');
    buffer.write('  state:     ANALYZE');
    return buffer.toString();
  }
}

// ─── Command ────────────────────────────────────────────────────────────────

class ImplementationStartCommand
    implements Command<ImplementationStartInput, ImplementationStartOutput> {
  @override
  final ImplementationStartInput input;
  final Assets? _assets;
  final GitCommandRunner _git;
  final IssueInfoProvider _issueInfo;
  final StartAnalyzeRunner _startAnalyze;

  ImplementationStartCommand(
    this.input, {
    Assets? assets,
    GitCommandRunner? gitCommandRunner,
    IssueInfoProvider? issueInfoProvider,
    StartAnalyzeRunner? startAnalyzeRunner,
  }) : _assets = assets,
       _git = gitCommandRunner ?? _defaultGit,
       _issueInfo = issueInfoProvider ?? _defaultIssueInfo,
       _startAnalyze = startAnalyzeRunner ?? _defaultStartAnalyze;

  @override
  String? validate() {
    if (input.issue.isEmpty) {
      return 'Missing --issue.\n'
          'Usage: iq implementation start --issue <number> (--plan | --apply)\n'
          'Example: iq implementation start --issue 40 --apply';
    }
    if (int.tryParse(input.issue) == null) {
      return 'The --issue value must be a number, got "${input.issue}".\n'
          'Usage: iq implementation start --issue <number> (--plan | --apply)\n'
          'Example: iq implementation start --issue 40 --apply';
    }
    return null;
  }

  String _branch = '';

  /// Three steps, over a branch name settled before the plan is built.
  ///
  /// **The issue's title is read once, here.** The branch name derives from it,
  /// so reading it again at perform time could produce a different branch from
  /// the one that was approved — a renamed issue between plan and apply, and
  /// the cycle opens somewhere nobody asked for.
  ///
  /// What comes first are preconditions, not steps: not a git repository, an
  /// issue `gh` cannot see, a title with nothing to slug. A plan built from any
  /// of them would describe work that will never happen.
  @override
  Future<List<Step>> steps() async {
    final projectRoot = getProjectRoot(input.workingDirectory);
    if (projectRoot == null) {
      throw CommandException(
        id: 'not-a-git-repo',
        message:
            'Not inside a git repository, so there is no place to open a cycle.\n'
            'Run `iq implementation start --issue ${input.issue} --apply` from '
            'within your project, or initialize one first with `git init`.',
        exitCode: ExitCode.validationFailed,
      );
    }

    final info = _issueInfo(input.issue, projectRoot);
    if (info == null) {
      throw CommandException(
        id: 'issue-not-found',
        message:
            'Could not read issue #${input.issue} from GitHub.\n'
            'Check that it exists and that `gh` is authenticated:\n'
            '  gh issue view ${input.issue}\n'
            '  gh auth status',
        exitCode: ExitCode.validationFailed,
      );
    }

    try {
      _branch = branchNameFor(issue: input.issue, title: info.title);
    } on ArgumentError catch (e) {
      throw CommandException(
        id: 'empty-slug',
        message:
            '${e.message}\n'
            'Rename the issue to something with letters or numbers, then retry.',
        exitCode: ExitCode.validationFailed,
      );
    }

    return [
      // AC3 — the workspace initializes itself when missing; the user never
      // has to remember `iq init`.
      EnsureWorkspace(projectRoot),
      CheckoutBranch(
        projectRoot: projectRoot,
        branch: _branch,
        git: _git,
        issue: input.issue,
      ),
      StartAnalyze(
        issue: input.issue,
        projectRoot: projectRoot,
        assets: _assets,
        run: _startAnalyze,
        branch: _branch,
      ),
    ];
  }

  @override
  ImplementationStartOutput describe(Execution execution) {
    final checkout = execution.outcomes
        .where((o) => o.values.containsKey('created'))
        .firstOrNull;
    return ImplementationStartOutput(
      issue: input.issue,
      branch: _branch,
      cleanroom: p.posix.join('cleanrooms', _branch),
      branchCreated: checkout?.values['created'] as bool? ?? false,
      initialized: execution.outcomes.any((o) => o.verb == 'initialize'),
    );
  }

  static ProcessResult _defaultGit(
    String workingDirectory,
    List<String> arguments,
  ) => Process.runSync('git', arguments, workingDirectory: workingDirectory);

  static ({String title, String state})? _defaultIssueInfo(
    String issue,
    String workingDirectory,
  ) {
    try {
      final result = Process.runSync('gh', [
        'issue',
        'view',
        issue,
        '--json',
        'title,state',
      ], workingDirectory: workingDirectory);
      if (result.exitCode != 0) return null;
      final decoded =
          jsonDecode(result.stdout.toString()) as Map<String, dynamic>;
      final title = (decoded['title'] as String?)?.trim() ?? '';
      if (title.isEmpty) return null;
      return (title: title, state: (decoded['state'] as String?) ?? '');
    } catch (_) {
      return null;
    }
  }

  static Future<({bool ok, String message})> _defaultStartAnalyze({
    required String issue,
    required String workingDirectory,
    Assets? assets,
  }) async {
    final command = StateTransitionCommand(
      StateTransitionInput(
        currentState: null,
        event: 'start_analyze',
        issue: issue,
        workingDirectory: workingDirectory,
      ),
      assets: assets,
    );
    final output = await command.execute();
    return (ok: output.allowed, message: output.message);
  }
}

// ─── Steps ──────────────────────────────────────────────────────────────────

/// Creates the Inquiry workspace when the repository has none.
///
/// The user never has to remember `iq init`: opening a cycle in a repository
/// that never had one is the ordinary first run, not an error.
class EnsureWorkspace implements Step {
  EnsureWorkspace(this.projectRoot);

  final String projectRoot;

  bool get _exists =>
      File(p.join(projectRoot, '.inquiry', 'config.yaml')).existsSync();

  @override
  Preview preview() => _exists
      ? Preview(verb: 'exists', target: '.inquiry/config.yaml')
      : Preview(
          verb: 'initialize',
          target: '.inquiry/',
          detail: 'the repository has no Inquiry workspace yet',
        );

  @override
  Future<Outcome> perform(StepContext context) async {
    if (_exists) return Outcome(verb: 'exists', target: '.inquiry/config.yaml');
    // InitCommand is idempotent and repo-scoped; reuse it rather than
    // reimplementing the workspace layout.
    InitCommand(InitInput(workingDirectory: projectRoot)).execute();
    return Outcome(verb: 'initialize', target: '.inquiry/');
  }
}

/// Checks out the cycle's branch, creating it when it does not yet exist.
class CheckoutBranch implements Step {
  CheckoutBranch({
    required this.projectRoot,
    required this.branch,
    required this.git,
    required this.issue,
  });

  final String projectRoot;
  final String branch;
  final GitCommandRunner git;
  final String issue;

  bool get _onIt => getCurrentBranch(projectRoot) == branch;

  bool get _exists =>
      git(projectRoot, [
        'rev-parse',
        '--verify',
        '--quiet',
        'refs/heads/$branch',
      ]).exitCode ==
      0;

  @override
  Preview preview() {
    if (_onIt) {
      return Preview(
        verb: 'stay',
        target: 'branch $branch',
        detail: 'already on it',
      );
    }
    return _exists
        ? Preview(verb: 'checkout', target: 'branch $branch')
        : Preview(
            verb: 'create',
            target: 'branch $branch',
            detail: 'derived from the title of issue #$issue',
          );
  }

  @override
  Future<Outcome> perform(StepContext context) async {
    if (_onIt) {
      return Outcome(
        verb: 'stay',
        target: 'branch $branch',
        values: {'created': false},
      );
    }

    final exists = _exists;
    final checkout = exists
        ? git(projectRoot, ['checkout', branch])
        : git(projectRoot, ['checkout', '-b', branch]);

    if (checkout.exitCode != 0) {
      throw CommandException(
        id: 'branch-checkout-failed',
        message:
            'Could not switch to branch "$branch":\n'
            '${_gitErrorOf(checkout)}\n'
            'Commit or stash your changes, then retry '
            '`iq implementation start --issue $issue --apply`.',
        exitCode: ExitCode.genericError,
      );
    }

    return Outcome(
      verb: exists ? 'checkout' : 'create',
      target: 'branch $branch',
      values: {'created': !exists},
    );
  }

  static String _gitErrorOf(ProcessResult r) {
    final err = r.stderr.toString().trim();
    if (err.isNotEmpty) return err;
    final out = r.stdout.toString().trim();
    return out.isNotEmpty ? out : 'git exited with code ${r.exitCode}';
  }
}

/// Fires the `start_analyze` transition.
///
/// Its `open_analysis_context` effect scaffolds the cleanroom under
/// `cleanrooms/<branch>/`. Last, because the branch has to exist first: the
/// cleanroom is named after it.
class StartAnalyze implements Step {
  StartAnalyze({
    required this.issue,
    required this.projectRoot,
    required this.assets,
    required this.run,
    required this.branch,
  });

  final String issue;
  final String projectRoot;
  final Assets? assets;
  final StartAnalyzeRunner run;
  final String branch;

  @override
  Preview preview() => Preview(
    verb: 'transition',
    target: 'to ANALYZE',
    detail: 'scaffolds cleanrooms/$branch/analyze/ for issue #$issue',
  );

  @override
  Future<Outcome> perform(StepContext context) async {
    final result = await run(
      issue: issue,
      workingDirectory: projectRoot,
      assets: assets,
    );
    if (!result.ok) {
      throw CommandException(
        id: 'transition-failed',
        message:
            'Branch "$branch" is ready but the transition to ANALYZE failed:\n'
            '${result.message}',
        exitCode: ExitCode.genericError,
      );
    }
    return Outcome(verb: 'transition', target: 'to ANALYZE');
  }
}
