import type {Runtime} from '@chainlink/cre-sdk';
import {encodeAbiParameters, parseAbiParameters, type Hex} from 'viem';

import {shouldSubmit, submitReport, type EvmClient} from '../../shared/offchain/checkUpkeep';
import {createNetworkHandler, initCronWorkflow} from '../../shared/offchain/network';
import {type Config, type NetworkConfig, configSchema} from './types';

export {configSchema};

const CHECK_DATA_TYPE = parseAbiParameters('address factory');

export function encodeCheckData(factory: string): Hex {
  return encodeAbiParameters(CHECK_DATA_TYPE, [factory as Hex]);
}

export function runForFactory(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  receiver: string,
  factory: string,
  label: string,
): string {
  const performData = shouldSubmit(runtime, evmClient, receiver, encodeCheckData(factory), label);
  if (!performData) return 'No refresh needed';

  const txHash = submitReport(runtime, evmClient, receiver, performData, label);
  return txHash ? `refreshed, tx=${txHash}` : 'submit skipped';
}

export const createFactoryHandler = (network: NetworkConfig, factory: string) => {
  const label = `${network.chainName}:${factory}`;
  return createNetworkHandler<Config>(network, label, (runtime, evmClient) =>
    runForFactory(runtime, evmClient, network.receiver, factory, label),
  );
};

export const initWorkflow = (config: Config) =>
  initCronWorkflow(config, (network) =>
    network.factories.map((factory) => createFactoryHandler(network, factory)),
  );
