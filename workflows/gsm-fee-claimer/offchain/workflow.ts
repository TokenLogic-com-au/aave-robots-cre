import {cre, getNetwork, handler, type Runtime} from '@chainlink/cre-sdk';
import {encodeAbiParameters, parseAbiParameters, type Address, type Hex} from 'viem';

import {
  estimateOnReport,
  MAX_WRITE_GAS,
  shouldSubmit,
  writeSignedReport,
  type EvmClient,
} from '../../shared/offchain/checkUpkeep';
import {type Config, type NetworkConfig, configSchema} from './types';

export {configSchema};

type ActiveNetwork = NetworkConfig & {receiver: Address};

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

  const estimate = estimateOnReport(runtime, evmClient, network.receiver, performData, label);
  if (estimate === null) return 'submit skipped';
  if (estimate > MAX_WRITE_GAS) {
    runtime.log(
      `[${label}] estimate ${estimate} exceeds max write gas ${MAX_WRITE_GAS} — skipping`,
    );
    return 'submit skipped';
  }
  const txHash = writeSignedReport(
    runtime,
    evmClient,
    network.receiver,
    performData,
    label,
    MAX_WRITE_GAS,
  );
  return txHash ? `fees distributed, tx=${txHash}` : 'submit skipped';
}

export const createReceiverHandler = (network: ActiveNetwork) => {
  return (runtime: Runtime<Config>): string => {
    const label = `${network.chainName}:${network.receiver}`;
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
      return runForNetwork(runtime, evmClient, network, label);
    } catch (e) {
      runtime.log(`[${label}] failed: ${e}`);
      return 'Processing failed';
    }
  };
};

export const initWorkflow = (config: Config) => {
  const cron = new cre.capabilities.CronCapability();
  return config.evms
    .filter((net): net is ActiveNetwork => net.receiver !== '')
    .map((net) => handler(cron.trigger({schedule: config.schedule}), createReceiverHandler(net)));
};
