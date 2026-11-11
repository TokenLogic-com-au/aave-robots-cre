import type {Runtime} from '@chainlink/cre-sdk';
import {decodeAbiParameters, encodeAbiParameters, parseAbiParameters, type Hex} from 'viem';

import {IPoolABI} from '../../shared/offchain/abi/IPool';
import {v3PoolsFor} from '../../shared/offchain/addresses';
import {shouldSubmit, submitReport, type EvmClient} from '../../shared/offchain/checkUpkeep';
import {type Config, configSchema} from '../../shared/offchain/config';
import {findEvents} from '../../shared/offchain/events';
import {
  createNetworkHandler,
  initCronWorkflow,
  type DeployedNetwork,
} from '../../shared/offchain/network';

export {configSchema};

type ActiveNetwork = DeployedNetwork<Config['evms'][number]>;

const POOLS_TYPE = parseAbiParameters('address[]');

export function encodePools(pools: readonly Hex[]): Hex {
  return encodeAbiParameters(POOLS_TYPE, [pools]);
}

export function decodePools(data: Hex): readonly Hex[] {
  const [pools] = decodeAbiParameters(POOLS_TYPE, data);
  return pools;
}

// All pools of the network go in one checkUpkeep, so they are minted in one write.
export function runForNetwork(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  network: ActiveNetwork,
  label: string,
): string {
  const pools = v3PoolsFor(network.chainName);
  const performData = shouldSubmit(runtime, evmClient, network.receiver, encodePools(pools), label);
  if (!performData) return 'No pool to mint';

  const mintable = decodePools(performData);
  runtime.log(`[${label}] mintable=${mintable.length}/${pools.length} (${mintable.join(', ')})`);

  const txHash = submitReport(runtime, evmClient, network.receiver, performData, label);
  if (!txHash) return 'submit skipped';

  const events = findEvents(runtime, evmClient, txHash, IPoolABI, 'MintedToTreasury', mintable);
  for (const {emitter, args} of events) {
    runtime.log(
      `[${network.chainName}:${emitter}] MintedToTreasury` +
        ` | reserve=${args.reserve}` +
        ` | amountMinted=${args.amountMinted}` +
        ` | tx=${txHash}`,
    );
  }
  if (events.length === 0) {
    runtime.log(`[${label}] no MintedToTreasury event found in tx ${txHash}`);
  }
  return `minted ${events.length} reserves on ${mintable.length} pools, tx=${txHash}`;
}

export const createReceiverHandler = (network: ActiveNetwork) => {
  const label = `${network.chainName}:${network.receiver}`;
  return createNetworkHandler<Config>(network, label, (runtime, evmClient) =>
    runForNetwork(runtime, evmClient, network, label),
  );
};

// Networks with no v3 pool in the address book register no trigger.
export const initWorkflow = (config: Config) =>
  initCronWorkflow(
    {...config, evms: config.evms.filter((network) => v3PoolsFor(network.chainName).length > 0)},
    createReceiverHandler,
  );
