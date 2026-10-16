import {cre, encodeCallMsg, getNetwork, handler, type Runtime} from '@chainlink/cre-sdk';
import {encodeFunctionData, zeroAddress, type Hex} from 'viem';

import {IAaveCREReceiverABI} from '../../shared/offchain/abi/IAaveCREReceiver';
import {shouldSubmit, submitReport} from '../../shared/offchain/checkUpkeep';
import {type Config, type NetworkConfig, configSchema} from './types';

export {configSchema};

type EvmClient = InstanceType<typeof cre.capabilities.EVMClient>;

// The receiver holds the voting machine immutable and pages through its proposals itself,
// so checkUpkeep takes no payload.
const EMPTY_CHECK_DATA = '0x' as Hex;

// Gas quota per CRE write (ChainWrite.EVM transaction gas limit, also the gas the DON attaches
// by default): a report estimated above it can't go through CRE.
export const MAX_WRITE_GAS = 16_777_216n;

/// Estimates `onReport(0x, performData)` on the receiver. Returns the gas, or `null` (after
/// logging) if the call would revert or needs more than `MAX_WRITE_GAS`.
export function estimateWithinQuota(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  receiver: string,
  performData: Hex,
  label: string,
): bigint | null {
  const data = encodeFunctionData({
    abi: IAaveCREReceiverABI,
    functionName: 'onReport',
    args: ['0x', performData],
  });
  let gas: bigint;
  try {
    gas = evmClient
      .estimateGas(runtime, {
        msg: encodeCallMsg({from: zeroAddress, to: receiver as Hex, data}),
      })
      .result().gas;
  } catch (e) {
    runtime.log(`[${label}] estimateGas failed for onReport — skipping: ${e}`);
    return null;
  }
  if (gas > MAX_WRITE_GAS) {
    runtime.log(
      `[${label}] onReport estimate ${gas} exceeds the CRE write gas quota ${MAX_WRITE_GAS} — skipping`,
    );
    return null;
  }
  return gas;
}

export function runForNetwork(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  receiver: string,
  label: string,
): string {
  const performData = shouldSubmit(runtime, evmClient, receiver, EMPTY_CHECK_DATA, label);
  if (!performData) return 'No action needed';

  if (estimateWithinQuota(runtime, evmClient, receiver, performData, label) === null) {
    return 'submit skipped';
  }
  // The shared submitReport estimates once more before signing and writing.
  const txHash = submitReport(runtime, evmClient, receiver, performData, label);
  return txHash ? `actions performed, tx=${txHash}` : 'submit skipped';
}

export const createReceiverHandler = (network: NetworkConfig) => {
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
      return runForNetwork(runtime, evmClient, network.receiver, label);
    } catch (e) {
      runtime.log(`[${label}] failed: ${e}`);
      return 'Processing failed';
    }
  };
};

// One cron trigger per voting chain with a deployed receiver.
export const initWorkflow = (config: Config) => {
  const cron = new cre.capabilities.CronCapability();
  return config.evms
    .filter((net) => net.chainName && net.receiver)
    .map((net) => handler(cron.trigger({schedule: config.schedule}), createReceiverHandler(net)));
};
