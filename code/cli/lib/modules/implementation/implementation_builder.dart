import 'package:modular_cli_sdk/modular_cli_sdk.dart';

import '../../assets.dart';
import 'commands/start.dart';

/// Registers the `implementation` module — the build phase of a cycle
/// (ANALYZE → PLAN → EXECUTE). `iq implementation start --issue <N>` opens it:
/// it creates the issue-linked branch, scaffolds the cleanroom, and enters
/// ANALYZE — the whole mechanical bootstrap in one explicit command.
void buildImplementationModule(ModuleBuilder m, {Assets? assets}) {
  m.command<ImplementationStartInput, ImplementationStartOutput>(
    'start',
    (req) => ImplementationStartCommand(
      ImplementationStartInput.fromCliRequest(req),
      assets: assets,
    ),
    description:
        'Start implementing an issue: create the linked branch, scaffold the cleanroom, and enter ANALYZE',
    globals: true,
    contract: ImplementationStartInput.contract,
  );
}
