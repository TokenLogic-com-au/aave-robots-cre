import {
  bigintToProtoBigInt,
  bytesToHex,
  cre,
  encodeCallMsg,
  hexToBase64,
  TxStatus,
  type Runtime,
} from '@chainlink/cre-sdk';
import {EVM_PB} from '@chainlink/cre-sdk/pb';
import {decodeFunctionResult, encodeFunctionData, zeroAddress, type Hex} from 'viem';

import {IAaveCREReceiverABI} from './abi/IAaveCREReceiver';
import {
  CALL_GAS_DENOMINATOR,
  CALL_GAS_NUMERATOR,
  MAX_WRITE_GAS,
  WRITE_OVERHEAD_GAS,
} from './constants';

export type EvmClient = InstanceType<typeof cre.capabilities.EVMClient>;

/// How `onReport` is estimated and written. Defaults suit a permissionless `onReport`; a robot
/// pinning the forwarder passes it as `from`, with the expected workflow id as `metadata`.
export type SubmitOptions = {
  from?: Hex;
  metadata?: Hex;
  gasLimit?: bigint;
};

/// Calls `checkUpkeep(checkData)` on the robot, at `blockNumber` if given (latest block
/// otherwise). Returns `performData` if the robot wants `onReport` submitted this tick, or
/// `null` if not.
export function shouldSubmit<TConfig>(
  runtime: Runtime<TConfig>,
  evmClient: EvmClient,
  robotAddress: string,
  checkData: Hex,
  label: string,
  blockNumber?: bigint,
): Hex | null {
  const calldata = encodeFunctionData({
    abi: IAaveCREReceiverABI,
    functionName: 'checkUpkeep',
    args: [checkData],
  });
  let data: Hex;
  try {
    const call = evmClient
      .callContract(runtime, {
        call: encodeCallMsg({from: zeroAddress, to: robotAddress as Hex, data: calldata}),
        ...(blockNumber === undefined ? {} : {blockNumber: bigintToProtoBigInt(blockNumber)}),
      })
      .result();
    data = bytesToHex(call.data);
  } catch (e) {
    runtime.log(`[${label}] checkUpkeep reverted — skipping: ${e}`);
    return null;
  }
  if (data === '0x') {
    runtime.log(`[${label}] checkUpkeep returned empty data — skipping`);
    return null;
  }

  const [upkeepNeeded, performData] = decodeFunctionResult({
    abi: IAaveCREReceiverABI,
    functionName: 'checkUpkeep',
    data,
  });
  runtime.log(`[${label}] checkUpkeep → upkeepNeeded=${upkeepNeeded}`);
  return upkeepNeeded ? performData : null;
}

/// Estimates `onReport(metadata, performData)` on the robot as `from` would call it.
/// Returns the gas, or `null` (after logging) if the call would revert.
export function estimateOnReport<TConfig>(
  runtime: Runtime<TConfig>,
  evmClient: EvmClient,
  robotAddress: string,
  performData: Hex,
  label: string,
  {from = zeroAddress, metadata = '0x'}: Pick<SubmitOptions, 'from' | 'metadata'> = {},
): bigint | null {
  const data = encodeFunctionData({
    abi: IAaveCREReceiverABI,
    functionName: 'onReport',
    args: [metadata, performData],
  });
  try {
    const {gas} = evmClient
      .estimateGas(runtime, {msg: encodeCallMsg({from, to: robotAddress as Hex, data})})
      .result();
    runtime.log(`[${label}] estimateGas(onReport) = ${gas}`);
    return gas;
  } catch (e) {
    runtime.log(`[${label}] estimateGas failed for onReport — skipping: ${e}`);
    return null;
  }
}

/// Gas a write needs for `onReport` to get `estimate`: the forwarder's overhead plus what it
/// keeps back from its call to the robot.
export function requiredWriteGas(estimate: bigint): bigint {
  return (estimate * CALL_GAS_NUMERATOR) / CALL_GAS_DENOMINATOR + WRITE_OVERHEAD_GAS;
}

/// Whether an `onReport` estimate fits a write of `gasLimit` gas.
export function fitsWriteQuota(estimate: bigint, gasLimit: bigint = MAX_WRITE_GAS): boolean {
  return requiredWriteGas(estimate) <= gasLimit;
}

/// Estimates `onReport`, then signs `performData` and writes it as its `report` directly to
/// the robot (no MailboxCRE indirection). The estimate only gates the write: it is skipped if
/// `onReport` would revert or not fit the quota, and the write always requests the full
/// `gasLimit`. Returns the tx hash, or `null` (after logging) if skipped, if the tx failed or if
/// `onReport` reverted inside it.
export function submitReport<TConfig>(
  runtime: Runtime<TConfig>,
  evmClient: EvmClient,
  robotAddress: string,
  performData: Hex,
  label: string,
  {from, metadata, gasLimit = MAX_WRITE_GAS}: SubmitOptions = {},
): string | null {
  const estimate = estimateOnReport(runtime, evmClient, robotAddress, performData, label, {
    from,
    metadata,
  });
  if (estimate === null) return null;
  if (!fitsWriteQuota(estimate, gasLimit)) {
    runtime.log(
      `[${label}] estimate ${estimate} (${requiredWriteGas(estimate)} with forwarder overhead) exceeds max write gas ${gasLimit} — skipping`,
    );
    return null;
  }

  const report = runtime
    .report({
      encodedPayload: hexToBase64(performData),
      encoderName: 'evm',
      signingAlgo: 'ecdsa',
      hashingAlgo: 'keccak256',
    })
    .result();

  const writeResult = evmClient
    .writeReport(runtime, {
      receiver: robotAddress,
      report,
      gasConfig: {gasLimit: gasLimit.toString()},
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
  const txHash = bytesToHex(writeResult.txHash);
  // The forwarder tx succeeds even when `onReport` reverts inside it.
  if (
    writeResult.receiverContractExecutionStatus === EVM_PB.ReceiverContractExecutionStatus.REVERTED
  ) {
    runtime.log(`[${label}] onReport reverted in tx ${txHash} — skipping`);
    return null;
  }
  return txHash;
}
