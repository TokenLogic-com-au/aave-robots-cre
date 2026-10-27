import {handler, logTriggerConfig, type Runtime} from '@chainlink/cre-sdk';
import {bytesToHex, toEventSelector, type Hex} from 'viem';

import * as AaveV3Ethereum from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3Ethereum';
import {shouldSubmit, submitReport, type EvmClient} from '../../shared/offchain/checkUpkeep';
import {EMPTY_CHECK_DATA} from '../../shared/offchain/constants';
import {
  createNetworkHandler,
  deployedNetworks,
  getEvmClient,
  initCronWorkflow,
} from '../../shared/offchain/network';
import {type Config, type NetworkConfig, configSchema} from './types';

export {configSchema};

// Emitted by the Pool when a liquidation leaves bad debt, i.e. when a reserve deficit grows.
export const DEFICIT_CREATED = toEventSelector('DeficitCreated(address,address,uint256)');

// Pool whose deficits the Umbrella on each chain covers.
export const POOL_BY_CHAIN: Record<string, Hex> = {
  'ethereum-mainnet': AaveV3Ethereum.POOL as Hex,
};

export function runForNetwork(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  receiver: string,
  label: string,
  blockNumber?: bigint,
): string {
  const performData = shouldSubmit(
    runtime,
    evmClient,
    receiver,
    EMPTY_CHECK_DATA,
    label,
    blockNumber,
  );
  if (!performData) return 'No slash needed';

  const txHash = submitReport(runtime, evmClient, receiver, performData, label);
  return txHash ? `slashed, tx=${txHash}` : 'submit skipped';
}

export const createReceiverHandler = (network: NetworkConfig, trigger = 'cron') => {
  const label = `${network.chainName}:${network.receiver}`;
  // `payload` is the cron `Payload` or the EVM `Log`. For a log, `checkUpkeep` is read at
  // the log's block: "latest" is resolved by each node and may not include it yet.
  return createNetworkHandler<Config>(
    network,
    `${label} (${trigger})`,
    (runtime, evmClient, payload) => {
      const log = payload as {txHash?: Uint8Array; blockNumber?: bigint} | undefined;
      const source = log?.txHash?.length ? `${trigger} ${bytesToHex(log.txHash)}` : trigger;
      return runForNetwork(
        runtime,
        evmClient,
        network.receiver,
        `${label} (${source})`,
        log?.blockNumber,
      );
    },
  );
};

// Per network: a cron, plus a `DeficitCreated` log trigger on the Pool so a new deficit is
// slashed within a few blocks. The cron is the fallback for deficits that don't come from
// a liquidation (e.g. a lowered Umbrella deficit offset) or a missed log.
export const initWorkflow = (config: Config) => [
  ...initCronWorkflow(config, (network) => createReceiverHandler(network)),
  ...deployedNetworks(config.evms).flatMap((network) => {
    const pool = POOL_BY_CHAIN[network.chainName];
    const evmClient = pool ? getEvmClient(network) : null;
    if (!evmClient) return [];

    const trigger = evmClient.logTrigger(
      logTriggerConfig({addresses: [pool], topics: [[DEFICIT_CREATED]], confidence: 'LATEST'}),
    );
    return [handler(trigger, createReceiverHandler(network, 'DeficitCreated'))];
  }),
];
