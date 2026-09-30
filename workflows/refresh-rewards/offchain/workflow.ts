import {cre, getNetwork, handler, type Runtime} from '@chainlink/cre-sdk';
import {encodeAbiParameters, parseAbiParameters, type Hex} from 'viem';

import {shouldSubmit, submitReport} from '../../shared/offchain/checkUpkeep';
import {type Config, type NetworkConfig, configSchema} from './types';

export {configSchema};

type EvmClient = InstanceType<typeof cre.capabilities.EVMClient>;

const CHECK_DATA_TYPE = parseAbiParameters('address factory');

export function encodeCheckData(factory: string): Hex {
  return encodeAbiParameters(CHECK_DATA_TYPE, [factory as Hex]);
}

export function runForFactory(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  receiver: string,
  factory: string,
  label: string,
): string {
  const performData = shouldSubmit(runtime, evmClient, receiver, encodeCheckData(factory), label);
  if (!performData) return 'No refresh needed';

  const txHash = submitReport(runtime, evmClient, receiver, performData, label);
  return txHash ? `refreshed, tx=${txHash}` : 'submit skipped';
}

export const createFactoryHandler = (network: NetworkConfig, factory: string) => {
  return (runtime: Runtime<Config>): string => {
    const label = `${network.chainName}:${factory}`;
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
      return runForFactory(runtime, evmClient, network.receiver, factory, label);
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
      net.factories.map((factory) =>
        handler(cron.trigger({schedule: config.schedule}), createFactoryHandler(net, factory)),
      ),
    );
};
