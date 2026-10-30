import {cre, getNetwork, handler, type Runtime} from '@chainlink/cre-sdk';
import type {Address} from 'viem';

import type {EvmClient} from './checkUpkeep';
import {MAX_WRITE_GAS, MAX_WRITE_GAS_BY_CHAIN} from './constants';

export type NetworkSelector = {chainName: string; isTestnet?: boolean};

export type DeployedNetwork<TNetwork extends {receiver: string}> = TNetwork & {receiver: Address};

// The client doesn't expose its chain, so remember it for the write quota.
const chainNames = new WeakMap<EvmClient, string>();

/// EVM client for the network, or `null` if CRE doesn't know it.
export function getEvmClient(network: NetworkSelector): EvmClient | null {
  const creNetwork = getNetwork({
    chainFamily: 'evm',
    chainSelectorName: network.chainName,
    isTestnet: network.isTestnet ?? false,
  });
  if (!creNetwork) return null;
  const evmClient = new cre.capabilities.EVMClient(creNetwork.chainSelector.selector);
  chainNames.set(evmClient, network.chainName);
  return evmClient;
}

/// Write gas quota of a chain, by CRE chain selector name.
export function maxWriteGasOf(chainName: string): bigint {
  return MAX_WRITE_GAS_BY_CHAIN[chainName] ?? MAX_WRITE_GAS;
}

/// Write gas quota of the client's chain; `MAX_WRITE_GAS` for a client `getEvmClient` didn't build.
export function maxWriteGas(evmClient: EvmClient): bigint {
  const chainName = chainNames.get(evmClient);
  return chainName ? maxWriteGasOf(chainName) : MAX_WRITE_GAS;
}

/// Networks whose receiver is deployed, i.e. set in the config.
export function deployedNetworks<TNetwork extends {chainName: string; receiver: string}>(
  networks: readonly TNetwork[],
): DeployedNetwork<TNetwork>[] {
  return networks.filter(
    (network): network is DeployedNetwork<TNetwork> => !!network.chainName && !!network.receiver,
  );
}

/// Trigger callback that resolves the network's EVM client and runs `run` with it, turning an
/// unknown network or a thrown error into a logged result instead of a failed execution.
export function createNetworkHandler<TConfig, TPayload = unknown>(
  network: NetworkSelector,
  label: string,
  run: (runtime: Runtime<TConfig>, evmClient: EvmClient, payload?: TPayload) => string,
): (runtime: Runtime<TConfig>, payload?: TPayload) => string {
  return (runtime, payload) => {
    const evmClient = getEvmClient(network);
    if (!evmClient) {
      runtime.log(`[${label}] network not found — skipping`);
      return 'Network not found';
    }
    try {
      return run(runtime, evmClient, payload);
    } catch (e) {
      runtime.log(`[${label}] failed: ${e}`);
      return 'Processing failed';
    }
  };
}

type CronCallback<TConfig> = (runtime: Runtime<TConfig>) => string;

/// One cron handler per callback `handlersFor` returns for each deployed network, all on
/// `config.schedule`.
export function initCronWorkflow<
  TConfig extends {schedule: string; evms: readonly {chainName: string; receiver: string}[]},
>(
  config: TConfig,
  handlersFor: (
    network: DeployedNetwork<TConfig['evms'][number]>,
  ) => CronCallback<TConfig> | CronCallback<TConfig>[],
) {
  const cron = new cre.capabilities.CronCapability();
  return deployedNetworks(config.evms).flatMap((network) =>
    [handlersFor(network)]
      .flat()
      .map((fn) => handler(cron.trigger({schedule: config.schedule}), fn)),
  );
}
