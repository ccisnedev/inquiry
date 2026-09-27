import 'package:modular_cli_sdk/modular_cli_sdk.dart';

import '../../assets.dart';
import 'commands/prompt.dart';
import 'commands/state.dart';
import 'commands/transition.dart';

void buildApeModule(ModuleBuilder m, {Assets? assets}) {
  m.query<ApePromptInput, ApePromptOutput>(
    'prompt',
    (req) =>
        ApePromptCommand(ApePromptInput.fromCliRequest(req), assets: assets),
    description: 'Assemble a sub-agent prompt from YAML + current FSM state',
    globals: true,
    contract: ApePromptInput.contract,
  );

  m.query<ApeStateInput, ApeStateOutput>(
    'state',
    (req) => ApeStateCommand(ApeStateInput.fromCliRequest(req), assets: assets),
    description: 'Show current APE sub-state and valid internal transitions',
    globals: true,
    contract: ApeStateInput.contract,
  );

  m.query<ApeTransitionInput, ApeTransitionOutput>(
    'transition',
    (req) => ApeTransitionCommand(
      ApeTransitionInput.fromCliRequest(req),
      assets: assets,
    ),
    description: 'Execute an APE-internal transition',
    globals: true,
    contract: ApeTransitionInput.contract,
  );
}
