import {cre, getNetwork, handler, type Runtime} from '@chainlink/cre-sdk';
import {encodeAbiParameters, parseAbiParameters, type Hex} from 'viem';

import {shouldSubmit, submitReport} from '../../shared/offchain/checkUpkeep';
import {type Config, type NetworkConfig, type Pool, configSchema} from './types';

export {configSchema};

type EvmClient = InstanceType<typeof cre.capabilities.EVMClient>;

const CHECK_DATA_TYPE = parseAbiParameters('address factory, address controller');

/// The receiver's `checkUpkeep` takes `(factory, controller)` and does the
/// stataToken enumeration + unregistered-reward scan itself, so the workflow
/// only forwards the pool addresses — no off-chain reads needed.
function encodeCheckData(pool: Pool): Hex {
  return encodeAbiParameters(CHECK_DATA_TYPE, [pool.factory as Hex, pool.controller as Hex]);
}

export function runForPool(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  receiver: string,
  pool: Pool,
  label: string,
): string {
  const performData = shouldSubmit(runtime, evmClient, receiver, encodeCheckData(pool), label);
  if (!performData) return 'No refresh needed';

  const txHash = submitReport(runtime, evmClient, receiver, performData, label);
  return txHash ? `refreshed, tx=${txHash}` : 'submit skipped';
}

export const createPoolHandler = (network: NetworkConfig, pool: Pool) => {
  return (runtime: Runtime<Config>): string => {
    const label = `${network.chainName}:${pool.factory}`;
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
      return runForPool(runtime, evmClient, network.receiver, pool, label);
    } catch (e) {
      runtime.log(`[${label}] failed: ${e}`);
      return 'Processing failed';
    }
  };
};

export const initWorkflow = (config: Config) => {
  const cron = new cre.capabilities.CronCapability();
  return config.evms
    .filter((net) => net.chainName && net.receiver)
    .flatMap((net) =>
      net.pools.map((pool) =>
        handler(cron.trigger({schedule: config.schedule}), createPoolHandler(net, pool)),
      ),
    );
};
