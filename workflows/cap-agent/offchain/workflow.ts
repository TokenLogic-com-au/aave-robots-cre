import {
  bytesToHex,
  cre,
  encodeCallMsg,
  getNetwork,
  handler,
  hexToBase64,
  TxStatus,
  type Runtime,
} from '@chainlink/cre-sdk';
import {encodeFunctionData, zeroAddress, type Hex} from 'viem';

import {IAaveCREReceiverABI} from '../../shared/offchain/abi/IAaveCREReceiver';
import {shouldSubmit} from '../../shared/offchain/checkUpkeep';
import {type Config, type NetworkConfig, configSchema} from './types';

export {configSchema};

type EvmClient = InstanceType<typeof cre.capabilities.EVMClient>;

// Gas the DON attaches to a chain write when no gasConfig is sent, i.e. the CRE write quota
// (16,777,216 since 2026-10-07). A write estimated above it would run out of gas inside the
// forwarder, so it is skipped instead.
export const MAX_WRITE_GAS = 16_777_216n;

// The receiver holds the AgentHub and the enabled agents, so checkUpkeep takes no payload.
const EMPTY_CHECK_DATA = '0x' as Hex;

/// Estimates `onReport('', performData)` on the receiver. Returns the gas, or `null` (after
/// logging) if the call would revert.
export function estimateOnReport(
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
  try {
    const {gas} = evmClient
      .estimateGas(runtime, {msg: encodeCallMsg({from: zeroAddress, to: receiver as Hex, data})})
      .result();
    runtime.log(`[${label}] estimateGas(onReport) = ${gas}`);
    return gas;
  } catch (e) {
    runtime.log(`[${label}] estimateGas failed for onReport — skipping: ${e}`);
    return null;
  }
}

/// Signs `performData` and writes it as the receiver's `onReport` report. Returns the tx hash,
/// or `null` (after logging) if the write did not succeed.
export function writeReport(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  receiver: string,
  performData: Hex,
  label: string,
): string | null {
  const report = runtime
    .report({
      encodedPayload: hexToBase64(performData),
      encoderName: 'evm',
      signingAlgo: 'ecdsa',
      hashingAlgo: 'keccak256',
    })
    .result();
  const result = evmClient.writeReport(runtime, {receiver, report}).result();

  if (result.txStatus !== TxStatus.SUCCESS) {
    runtime.log(
      `[${label}] writeReport status=${result.txStatus} err=${result.errorMessage ?? ''} — skipping`,
    );
    return null;
  }
  if (!result.txHash || result.txHash.length === 0) {
    runtime.log(`[${label}] writeReport returned SUCCESS but no txHash — skipping`);
    return null;
  }
  return bytesToHex(result.txHash);
}

export function runForNetwork(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  receiver: string,
  label: string,
): string {
  const performData = shouldSubmit(runtime, evmClient, receiver, EMPTY_CHECK_DATA, label);
  if (!performData) return 'No injection needed';

  const gas = estimateOnReport(runtime, evmClient, receiver, performData, label);
  if (gas === null) return 'submit skipped';
  if (gas > MAX_WRITE_GAS) {
    runtime.log(
      `[${label}] estimate ${gas} exceeds the CRE write gas quota ${MAX_WRITE_GAS} — skipping`,
    );
    return 'submit skipped: gas above quota';
  }

  const txHash = writeReport(runtime, evmClient, receiver, performData, label);
  return txHash ? `injected, tx=${txHash}` : 'submit skipped';
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

// One cron trigger per chain with a deployed receiver.
export const initWorkflow = (config: Config) => {
  const cron = new cre.capabilities.CronCapability();
  return config.evms
    .filter((net) => net.chainName && net.receiver)
    .map((net) => handler(cron.trigger({schedule: config.schedule}), createReceiverHandler(net)));
};
