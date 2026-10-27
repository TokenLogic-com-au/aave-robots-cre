import type {Runtime} from '@chainlink/cre-sdk';
import {encodeAbiParameters, parseAbiParameters, type Address, type Hex} from 'viem';

import {shouldSubmit, submitReport, type EvmClient} from '../../shared/offchain/checkUpkeep';
import {
  createNetworkHandler,
  initCronWorkflow,
  type DeployedNetwork,
} from '../../shared/offchain/network';
import {type Config, type NetworkConfig, configSchema} from './types';

export {configSchema};

type ActiveNetwork = DeployedNetwork<NetworkConfig>;

// The receiver holds no target list: the GSMs to probe and the threshold travel in checkData.
export function encodeCheckData(gsms: readonly Address[], minFees: bigint): Hex {
  return encodeAbiParameters(parseAbiParameters('address[], uint256'), [gsms, minFees]);
}

export function runForNetwork(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  network: ActiveNetwork,
  label: string,
): string {
  const checkData = encodeCheckData(network.gsms, network.minFees);
  const performData = shouldSubmit(runtime, evmClient, network.receiver, checkData, label);
  if (!performData) return 'No fees to distribute';

  const txHash = submitReport(runtime, evmClient, network.receiver, performData, label);
  return txHash ? `fees distributed, tx=${txHash}` : 'submit skipped';
}

export const createReceiverHandler = (network: ActiveNetwork) => {
  const label = `${network.chainName}:${network.receiver}`;
  return createNetworkHandler<Config>(network, label, (runtime, evmClient) =>
    runForNetwork(runtime, evmClient, network, label),
  );
};

export const initWorkflow = (config: Config) => initCronWorkflow(config, createReceiverHandler);
