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
import {
  decodeAbiParameters,
  encodeAbiParameters,
  encodeFunctionData,
  parseAbiParameters,
  zeroAddress,
  type Hex,
} from 'viem';

import {IAaveCREReceiverABI} from '../../shared/offchain/abi/IAaveCREReceiver';
import {shouldSubmit} from '../../shared/offchain/checkUpkeep';
import {type Config, type NetworkConfig, configSchema} from './types';

export {configSchema};

type EvmClient = InstanceType<typeof cre.capabilities.EVMClient>;

// The receiver holds the PayloadsController immutable and scans it itself, so
// checkUpkeep takes no payload.
const EMPTY_CHECK_DATA = '0x' as Hex;

// CRE's ChainWrite.EVM gas quota. A payload estimated above it can't execute through CRE
// and would fail (and be retried) every tick, so it's skipped and left to a manual call.
export const MAX_WRITE_GAS = 16_777_216n;

const PAYLOAD_IDS = parseAbiParameters('uint40[]');

export function encodePayloadIds(ids: readonly number[]): Hex {
  return encodeAbiParameters(PAYLOAD_IDS, [ids]);
}

export function decodePayloadIds(data: Hex): readonly number[] {
  return decodeAbiParameters(PAYLOAD_IDS, data)[0];
}

/// Writes a report executing a single payload, unless its `onReport` estimate reverts or
/// exceeds the CRE write quota. Returns the tx hash, or `null` (after logging) if skipped.
export function executePayload(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  receiver: string,
  payloadId: number,
  label: string,
): string | null {
  const report = encodePayloadIds([payloadId]);
  const calldata = encodeFunctionData({
    abi: IAaveCREReceiverABI,
    functionName: 'onReport',
    args: ['0x', report],
  });

  let estimate: bigint;
  try {
    estimate = evmClient
      .estimateGas(runtime, {
        msg: encodeCallMsg({from: zeroAddress, to: receiver as Hex, data: calldata}),
      })
      .result().gas;
  } catch (e) {
    runtime.log(`[${label}] estimateGas failed for onReport — skipping: ${e}`);
    return null;
  }
  runtime.log(`[${label}] estimateGas(onReport) = ${estimate}`);
  if (estimate > MAX_WRITE_GAS) {
    runtime.log(
      `[${label}] estimate ${estimate} exceeds max write gas ${MAX_WRITE_GAS} — skipping`,
    );
    return null;
  }

  const signed = runtime
    .report({
      encodedPayload: hexToBase64(report),
      encoderName: 'evm',
      signingAlgo: 'ecdsa',
      hashingAlgo: 'keccak256',
    })
    .result();
  const writeResult = evmClient
    .writeReport(runtime, {
      receiver,
      report: signed,
      gasConfig: {gasLimit: MAX_WRITE_GAS.toString()},
    })
    .result();

  if (writeResult.txStatus !== TxStatus.SUCCESS) {
    runtime.log(
      `[${label}] writeReport status=${writeResult.txStatus} err=${writeResult.errorMessage ?? ''} — skipping`,
    );
    return null;
  }
  if (!writeResult.txHash || writeResult.txHash.length === 0) {
    runtime.log(`[${label}] writeReport returned SUCCESS but no txHash — skipping`);
    return null;
  }
  return bytesToHex(writeResult.txHash);
}

// One report per payload: a reverting or oversized payload can't block the others, which
// BGD's keeper achieved by executing one payload picked at random per upkeep.
export function runForNetwork(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  receiver: string,
  label: string,
): string {
  const performData = shouldSubmit(runtime, evmClient, receiver, EMPTY_CHECK_DATA, label);
  if (!performData) return 'No payload to execute';

  const executed: string[] = [];
  for (const payloadId of decodePayloadIds(performData)) {
    const txHash = executePayload(
      runtime,
      evmClient,
      receiver,
      payloadId,
      `${label} payload ${payloadId}`,
    );
    if (txHash) executed.push(`${payloadId}:${txHash}`);
  }
  return executed.length > 0 ? `executed ${executed.join(', ')}` : 'submit skipped';
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
