import 'dart:io';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';

import '../../hosts/deployer.dart';
import '../../hosts/opencode_ollama_configurator.dart';
import 'commands/clean.dart';
import 'commands/get.dart';

void buildHostModule(
  ModuleBuilder m, {
  required HostDeployer deployer,
  required HostDeployer cleaner,
}) {
  m.command<HostGetInput, HostGetOutput>(
    'get',
    (req) => HostGetCommand(
      HostGetInput.fromCliRequest(req),
      deployer: deployer,
      configurator: OpenCodeOllamaConfigurator(
        run: Process.run,
        fs: RealConfigFs(),
        homeDir: deployer.homeDir,
      ),
    ),
    description: 'Install Inquiry (agent + skills) globally for a host',
    globals: true,
    contract: HostGetInput.contract,
  );

  m.command<HostCleanInput, HostCleanOutput>(
    'clean',
    (req) =>
        HostCleanCommand(HostCleanInput.fromCliRequest(req), deployer: cleaner),
    description: 'Remove deployed Inquiry files from all hosts',
    globals: true,
    contract: HostCleanInput.contract,
  );
}
