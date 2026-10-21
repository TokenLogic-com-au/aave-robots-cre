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

const EMPTY_CHECK_DATA = '0x' as Hex;

// Gas quota per CRE write; every write requests all of it.
export const MAX_WRITE_GAS = 16_777_216n;
// Forwarder report verification and call overhead on top of onReport.
export const WRITE_OVERHEAD_GAS = 250_000n;

/// Whether `onReport` estimated at `estimate` fits a CRE write: the forwarder passes on at most
/// 63/64 of its remaining gas (EIP-150).
export function fitsWriteQuota(estimate: bigint): boolean {
  return (estimate * 64n) / 63n + WRITE_OVERHEAD_GAS <= MAX_WRITE_GAS;
}

function estimateOnReport(
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

/// Signs `performData` and writes it to the receiver with the full write quota.
function writeReport(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  receiver: string,
  performData: Hex,
  label: string,
): string {
  const report = runtime
    .report({
      encodedPayload: hexToBase64(performData),
      encoderName: 'evm',
      signingAlgo: 'ecdsa',
      hashingAlgo: 'keccak256',
    })
    .result();
  const reply = evmClient
    .writeReport(runtime, {
      receiver,
      report,
      gasConfig: {gasLimit: MAX_WRITE_GAS.toString()},
    })
    .result();

  if (reply.txStatus !== TxStatus.SUCCESS) {
    runtime.log(
      `[${label}] writeReport status=${reply.txStatus} err=${reply.errorMessage ?? ''} — skipping`,
    );
    return 'submit skipped';
  }
  const txHash = reply.txHash?.length ? bytesToHex(reply.txHash) : '';
  // The forwarder tx succeeds even when onReport reverts inside it.
  if (reply.receiverContractExecutionStatus === EVM_PB.ReceiverContractExecutionStatus.REVERTED) {
    runtime.log(`[${label}] onReport reverted in tx ${txHash}`);
    return `onReport reverted, tx=${txHash}`;
  }
  if (!txHash) {
    runtime.log(`[${label}] writeReport returned SUCCESS but no txHash — skipping`);
    return 'submit skipped';
  }
  return `actions performed, tx=${txHash}`;
}

export function runForNetwork(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  receiver: string,
  label: string,
): string {
  const performData = shouldSubmit(runtime, evmClient, receiver, EMPTY_CHECK_DATA, label);
  if (!performData) return 'No action needed';

  const estimate = estimateOnReport(runtime, evmClient, receiver, performData, label);
  if (estimate === null) return 'submit skipped';
  if (!fitsWriteQuota(estimate)) {
    runtime.log(`[${label}] onReport estimate ${estimate} exceeds the CRE write quota — skipping`);
    return 'submit skipped';
  }
  return writeReport(runtime, evmClient, receiver, performData, label);
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
