import type {Runtime} from '@chainlink/cre-sdk';
import {decodeAbiParameters, encodeAbiParameters, parseAbiParameters, type Hex} from 'viem';

import {shouldSubmit, submitReport, type EvmClient} from '../../shared/offchain/checkUpkeep';
import {type Config, type NetworkConfig, configSchema} from '../../shared/offchain/config';
import {EMPTY_CHECK_DATA} from '../../shared/offchain/constants';
import {createNetworkHandler, initCronWorkflow} from '../../shared/offchain/network';

export {configSchema};

const PAYLOAD_IDS = parseAbiParameters('uint40[]');

export function encodePayloadIds(ids: readonly number[]): Hex {
  return encodeAbiParameters(PAYLOAD_IDS, [ids]);
}

export function decodePayloadIds(data: Hex): readonly number[] {
  return decodeAbiParameters(PAYLOAD_IDS, data)[0];
}

// One report per payload, so a reverting or oversized payload can't block the others.
export function runForNetwork(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  receiver: string,
  label: string,
): string {
  const performData = shouldSubmit(runtime, evmClient, receiver, EMPTY_CHECK_DATA, label);
  if (!performData) return 'No payload to execute';

  const executed: string[] = [];
  for (const payloadId of decodePayloadIds(performData)) {
    const txHash = submitReport(
      runtime,
      evmClient,
      receiver,
      encodePayloadIds([payloadId]),
      `${label} payload ${payloadId}`,
    );
    if (txHash) executed.push(`${payloadId}:${txHash}`);
  }
  return executed.length > 0 ? `executed ${executed.join(', ')}` : 'submit skipped';
}

export const createReceiverHandler = (network: NetworkConfig) => {
  const label = `${network.chainName}:${network.receiver}`;
  return createNetworkHandler<Config>(network, label, (runtime, evmClient) =>
    runForNetwork(runtime, evmClient, network.receiver, label),
  );
};

export const initWorkflow = (config: Config) => initCronWorkflow(config, createReceiverHandler);
