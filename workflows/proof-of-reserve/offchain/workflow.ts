import type {Runtime} from '@chainlink/cre-sdk';
import {encodeAbiParameters, parseAbiParameters, type Hex} from 'viem';

import {shouldSubmit, submitReport, type EvmClient} from '../../shared/offchain/checkUpkeep';
import {createNetworkHandler, initCronWorkflow} from '../../shared/offchain/network';
import {type Config, type NetworkConfig, configSchema} from './types';

export {configSchema};

const CHECK_DATA_TYPE = parseAbiParameters('address executor');

export function encodeCheckData(executor: string): Hex {
  return encodeAbiParameters(CHECK_DATA_TYPE, [executor as Hex]);
}

export function runForExecutor(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  receiver: string,
  executor: string,
  label: string,
): string {
  const performData = shouldSubmit(runtime, evmClient, receiver, encodeCheckData(executor), label);
  if (!performData) return 'No emergency action needed';

  const txHash = submitReport(runtime, evmClient, receiver, performData, label);
  return txHash ? `executed, tx=${txHash}` : 'submit skipped';
}

export const createExecutorHandler = (network: NetworkConfig, executor: string) => {
  const label = `${network.chainName}:${executor}`;
  return createNetworkHandler<Config>(network, label, (runtime, evmClient) =>
    runForExecutor(runtime, evmClient, network.receiver, executor, label),
  );
};

export const initWorkflow = (config: Config) =>
  initCronWorkflow(config, (network) =>
    network.executors.map((executor) => createExecutorHandler(network, executor)),
  );
