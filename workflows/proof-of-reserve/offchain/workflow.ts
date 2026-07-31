import {cre, getNetwork, handler, type Runtime} from '@chainlink/cre-sdk';
import {encodeAbiParameters, parseAbiParameters, type Hex} from 'viem';

import {shouldSubmit, submitReport} from '../../shared/offchain/checkUpkeep';
import {type Config, type NetworkConfig, configSchema} from './types';

export {configSchema};

type EvmClient = InstanceType<typeof cre.capabilities.EVMClient>;

const CHECK_DATA_TYPE = parseAbiParameters('address executor');

function encodeCheckData(executor: string): Hex {
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
  return (runtime: Runtime<Config>): string => {
    const label = `${network.chainName}:${executor}`;
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
      return runForExecutor(runtime, evmClient, network.receiver, executor, label);
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
      net.executors.map((executor) =>
        handler(cron.trigger({schedule: config.schedule}), createExecutorHandler(net, executor)),
      ),
    );
};
