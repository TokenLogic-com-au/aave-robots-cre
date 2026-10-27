import type {Runtime} from '@chainlink/cre-sdk';

import {shouldSubmit, submitReport, type EvmClient} from '../../shared/offchain/checkUpkeep';
import {configSchema, type Config, type NetworkConfig} from '../../shared/offchain/config';
import {EMPTY_CHECK_DATA} from '../../shared/offchain/constants';
import {createNetworkHandler, initCronWorkflow} from '../../shared/offchain/network';

export {configSchema};

export function runForNetwork(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  receiver: string,
  label: string,
): string {
  const performData = shouldSubmit(runtime, evmClient, receiver, EMPTY_CHECK_DATA, label);
  if (!performData) return 'No action needed';

  const txHash = submitReport(runtime, evmClient, receiver, performData, label);
  return txHash ? `actions performed, tx=${txHash}` : 'submit skipped';
}

export const createReceiverHandler = (network: NetworkConfig) => {
  const label = `${network.chainName}:${network.receiver}`;
  return createNetworkHandler<Config>(network, label, (runtime, evmClient) =>
    runForNetwork(runtime, evmClient, network.receiver, label),
  );
};

export const initWorkflow = (config: Config) => initCronWorkflow(config, createReceiverHandler);
