import {cre, getNetwork, handler, logTriggerConfig, type Runtime} from '@chainlink/cre-sdk';
import {bytesToHex, toEventSelector, type Hex} from 'viem';

import * as AaveV3Ethereum from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3Ethereum';
import {shouldSubmit, submitReport} from '../../shared/offchain/checkUpkeep';
import {type Config, type NetworkConfig, configSchema} from './types';

export {configSchema};

type EvmClient = InstanceType<typeof cre.capabilities.EVMClient>;

// The receiver holds the Umbrella immutable and enumerates the stake tokens
// itself, so checkUpkeep takes no payload.
const EMPTY_CHECK_DATA = '0x' as Hex;

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
  // `payload` is the cron `Payload` or the EVM `Log`. For a log, `checkUpkeep` is read at
  // the log's block: "latest" is resolved by each node and may not include it yet.
  return (runtime: Runtime<Config>, payload?: unknown): string => {
    const log = payload as {txHash?: Uint8Array; blockNumber?: bigint} | undefined;
    const source = log?.txHash?.length ? `${trigger} ${bytesToHex(log.txHash)}` : trigger;
    const label = `${network.chainName}:${network.receiver} (${source})`;
    const creNetwork = getNetwork({
      chainFamily: 'evm',
      chainSelectorName: network.chainName,
      isTestnet: network.isTestnet,
    });
    if (!creNetwork) {
      runtime.log(`[${label}] network not found — skipping`);
      return 'Network not found';
    }
    const evmClient = new cre.capabilities.EVMClient(creNetwork.chainSelector.selector);

    try {
      return runForNetwork(runtime, evmClient, network.receiver, label, log?.blockNumber);
    } catch (e) {
      runtime.log(`[${label}] failed: ${e}`);
      return 'Processing failed';
    }
  };
};

// Per network: a `DeficitCreated` log trigger on the Pool, so a new deficit is slashed
// within a few blocks, plus a slower cron as fallback for deficits that don't come from a
// liquidation (e.g. a lowered Umbrella deficit offset) or a missed log.
export const initWorkflow = (config: Config) => {
  const cron = new cre.capabilities.CronCapability();
  return config.evms
    .filter((net) => net.chainName && net.receiver)
    .flatMap((net) => {
      const cronHandler = handler(
        cron.trigger({schedule: config.schedule}),
        createReceiverHandler(net),
      );
      const pool = POOL_BY_CHAIN[net.chainName];
      const creNetwork = getNetwork({
        chainFamily: 'evm',
        chainSelectorName: net.chainName,
        isTestnet: net.isTestnet,
      });
      if (!pool || !creNetwork) return [cronHandler];

      const evmClient = new cre.capabilities.EVMClient(creNetwork.chainSelector.selector);
      const trigger = evmClient.logTrigger(
        logTriggerConfig({addresses: [pool], topics: [[DEFICIT_CREATED]], confidence: 'LATEST'}),
      );
      return [cronHandler, handler(trigger, createReceiverHandler(net, 'DeficitCreated'))];
    });
};
