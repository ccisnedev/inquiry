import 'package:modular_cli_sdk/modular_cli_sdk.dart';

import '../../assets.dart';
import 'commands/state.dart';
import 'commands/transition.dart';

void buildFsmModule(ModuleBuilder m, {Assets? assets}) {
  m.query<FsmStateInput, FsmStateOutput>(
    'state',
    (req) => FsmStateCommand(FsmStateInput.fromCliRequest(req), assets: assets),
    description: 'Show current FSM state, valid transitions, and active APEs',
    globals: true,
    contract: FsmStateInput.contract,
  );

  m.query<StateTransitionInput, StateTransitionOutput>(
    'transition',
    (req) => StateTransitionCommand(
      StateTransitionInput.fromCliRequest(req),
      assets: assets,
    ),
    description: 'Run a deterministic FSM transition',
    globals: true,
    contract: StateTransitionInput.contract,
  );
}
