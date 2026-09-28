/// `inquiry` (no args) — displays TUI with FSM diagram and version.
library;

import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';

import '../../../src/version.dart';
import '../../../src/version_check.dart';

// ─── Input ──────────────────────────────────────────────────────────────────

/// Input for the TUI command.
///
/// No parameters required — displays static information.
class TuiInput extends Input {
  TuiInput();

  factory TuiInput.fromCliRequest(CliRequest req) => TuiInput();

  /// Declares an EMPTY contract: this command accepts no option at all, so any
  /// option passed to it is refused. Omitting `contract` would mean "declares
  /// nothing" — which is how `iq init --host claude` used to run, doing nothing
  /// the flag implied.
  static const CliContract contract = CliContract.none;

  @override
  Map<String, dynamic> toJson() => {};
}

// ─── Output ─────────────────────────────────────────────────────────────────

/// Output for the TUI command.
class TuiOutput extends Output {
  final String version;
  final String diagram;

  TuiOutput({required this.version, required this.diagram});

  @override
  Map<String, dynamic> toJson() => {'version': version, 'diagram': diagram};

  @override
  int get exitCode => ExitCode.ok;

  /// Returns only the diagram for text mode (no field labels).
  @override
  String? toText() => diagram;
}

// ─── Command ────────────────────────────────────────────────────────────────

/// Command that displays the APE FSM diagram and version.
class TuiCommand implements Query<TuiInput, TuiOutput> {
  @override
  final TuiInput input;
  final Future<VersionCheckResult> Function({required String currentVersion})?
  _versionChecker;

  TuiCommand(
    this.input, {
    Future<VersionCheckResult> Function({required String currentVersion})?
    versionChecker,
  }) : _versionChecker = versionChecker;

  @override
  String? validate() => null;

  @override
  Future<TuiOutput> execute() async {
    var diagram = _buildDiagram(inquiryVersion);

    // Non-blocking version check
    try {
      final checker =
          _versionChecker ??
          ({required String currentVersion}) =>
              checkLatestVersion(currentVersion: currentVersion);
      final result = await checker(currentVersion: inquiryVersion);
      if (result.updateAvailable && result.latestVersion != null) {
        diagram +=
            "\n\nUpdate available: $inquiryVersion → ${result.latestVersion}"
            " — run 'iq upgrade --apply'";
      }
    } catch (_) {
      // Silent on failure
    }

    return TuiOutput(version: inquiryVersion, diagram: diagram);
  }
}

// ─── Helpers ────────────────────────────────────────────────────────────────

// ANSI escape codes for terminal colors.
const _r = '\x1B[0m'; // reset
const _b = '\x1B[1m'; // bold
const _d = '\x1B[2m'; // dim
const _wht = '\x1B[37m'; // white
const _red = '\x1B[31m'; // red
// const _grn = '\x1B[32m'; // green
const _ylw = '\x1B[33m'; // yellow
// const _blu = '\x1B[34m'; // blue
// const _mag = '\x1B[35m'; // magenta
// const _cyn = '\x1B[36m'; // cyan
const _bgr = '\x1B[92m'; // bright green

/// Builds the FSM diagram with the given version.
String _buildDiagram(String version) {
  // Logo: serif "i" — beacon (●) is the dot, ──█── are the serifs
  final logo =
      '\n$_bgr  ●    $_r'
      '\n$_wht ▀█ ▄▀▀█$_r  $_b${_red}Inquiry$_r v$version'
      '\n$_wht▄▄█▄▀▄▄█$_r  ${_d}powered by the Finite APE Machine$_r'
      '\n$_wht       ▀$_r';

  // FSM: backward arrows above, Evolution loop below
  final fsm =
      '$_d             ╭─────────────────────╮$_r\n'
      '$_d             ▼                     │$_r\n'
      '  Idle$_r $_d──>$_r $_b${_red}Analyze$_r $_d──>$_r $_b${_red}Plan$_r $_d──>$_r $_b${_red}Execute$_r $_d──>$_r End$_r $_d──>$_r Idle\n'
      '$_d             ▲           │                   $_ylw│$_r        $_d$_ylw▲$_r\n'
      '$_d             ╰───────────╯                   $_ylw▼$_r        $_d$_ylw│$_r\n'
      '$_d                                        ${_ylw}Evolution$_r$_d$_ylw ────╯$_r';

  final footer =
      '  ${_d}Commands: init, doctor, version$_r\n'
      '  ${_d}Run: iq --help$_r';

  return '$logo\n\n$fsm\n\n$footer';
}
