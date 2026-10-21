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
import {EVM_PB} from '@chainlink/cre-sdk/pb';
import {encodeFunctionData, zeroAddress, type Hex} from 'viem';

import {IAaveCREReceiverABI} from '../../shared/offchain/abi/IAaveCREReceiver';
import {shouldSubmit} from '../../shared/offchain/checkUpkeep';
import {type Config, type NetworkConfig, configSchema} from './types';

export {configSchema};

type EvmClient = InstanceType<typeof cre.capabilities.EVMClient>;

// The receiver holds the Governance immutable and scans the proposals itself.
const EMPTY_CHECK_DATA = '0x' as Hex;

// Gas quota per CRE write, which the DON uses as the gas limit when no gasConfig is sent.
export const MAX_WRITE_GAS = 16_777_216n;

// Forwarder report verification and call overhead on top of the `onReport` estimate.
export const WRITE_OVERHEAD_GAS = 250_000n;

/// Whether an `onReport` estimate fits the write quota once the forwarder overhead and the
/// 1/64 of gas withheld from its call to the receiver are added.
export function fitsWriteQuota(estimate: bigint): boolean {
  return (estimate * 64n) / 63n + WRITE_OVERHEAD_GAS <= MAX_WRITE_GAS;
}

/// Estimates `onReport('0x', performData)` on the receiver. Returns `null` (after logging) if it
/// reverts.
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
      .estimateGas(runtime, {
        msg: encodeCallMsg({from: zeroAddress, to: receiver as Hex, data}),
      })
      .result();
    runtime.log(`[${label}] estimateGas(onReport) = ${gas}`);
    return gas;
  } catch (e) {
    runtime.log(`[${label}] estimateGas failed for onReport — skipping: ${e}`);
    return null;
  }
}

/// Signs `performData` and writes it to the receiver. Returns the tx hash, or `null` (after
/// logging) if the tx or the receiver's `onReport` failed.
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
  const txHash = bytesToHex(result.txHash);
  if (result.receiverContractExecutionStatus === EVM_PB.ReceiverContractExecutionStatus.REVERTED) {
    runtime.log(`[${label}] onReport reverted in the forwarder tx ${txHash}`);
    return null;
  }
  return txHash;
}

export function runForNetwork(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  receiver: string,
  label: string,
): string {
  const performData = shouldSubmit(runtime, evmClient, receiver, EMPTY_CHECK_DATA, label);
  if (!performData) return 'No action needed';

  // Only used for the quota check, never as the gas limit: with too little gas `onReport` can
  // succeed while a Governance call or its a.DI forward fails.
  const estimate = estimateOnReport(runtime, evmClient, receiver, performData, label);
  if (estimate === null) return 'submit skipped';
  if (!fitsWriteQuota(estimate)) {
    runtime.log(
      `[${label}] estimate ${estimate} plus overhead exceeds max write gas ${MAX_WRITE_GAS} — skipping`,
    );
    return 'submit skipped';
  }

  const txHash = writeReport(runtime, evmClient, receiver, performData, label);
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

export const initWorkflow = (config: Config) => {
  const cron = new cre.capabilities.CronCapability();
  return config.evms
    .filter((net) => net.chainName && net.receiver)
    .map((net) => handler(cron.trigger({schedule: config.schedule}), createReceiverHandler(net)));
};
