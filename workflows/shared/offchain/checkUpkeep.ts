import {
  bytesToHex,
  cre,
  encodeCallMsg,
  hexToBase64,
  TxStatus,
  type Runtime,
} from '@chainlink/cre-sdk';
import {decodeFunctionResult, encodeFunctionData, zeroAddress, type Hex} from 'viem';

import {IAaveCREReceiverABI} from './abi/IAaveCREReceiver';

export type EvmClient = InstanceType<typeof cre.capabilities.EVMClient>;

// Gas quota per CRE write (`ChainWrite.EVM.TransactionGasLimit`, also the DON default).
// Requesting it explicitly keeps the simulator (which otherwise estimates) in line with
// production; an estimate above it means the write cannot go through CRE.
export const MAX_WRITE_GAS = 10_000_000n;

/// Calls `checkUpkeep(checkData)` on the robot. Returns `performData` if the
/// robot wants `onReport` submitted this tick, or `null` if not.
export function shouldSubmit<TConfig>(
  runtime: Runtime<TConfig>,
  evmClient: EvmClient,
  robotAddress: string,
  checkData: Hex,
  label: string,
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
  {from = zeroAddress, metadata = '0x'}: {from?: Hex; metadata?: Hex} = {},
): bigint | null {
  const onReportCalldata = encodeFunctionData({
    abi: IAaveCREReceiverABI,
    functionName: 'onReport',
    args: [metadata, performData],
  });
  try {
    const estimate = evmClient
      .estimateGas(runtime, {
        msg: encodeCallMsg({from, to: robotAddress as Hex, data: onReportCalldata}),
      })
      .result();
    runtime.log(`[${label}] estimateGas(onReport) = ${estimate.gas.toString()}`);
    return estimate.gas;
  } catch (e) {
    runtime.log(`[${label}] estimateGas failed for onReport — skipping: ${e}`);
    return null;
  }
}

/// Signs `performData` and writes it as the `report` argument of `onReport`
/// directly to the robot (no MailboxCRE indirection — `onReport` is assumed
/// permissionless). Returns the tx hash on success, `null` if the pre-flight
/// gas estimation reverted.
export function submitReport<TConfig>(
  runtime: Runtime<TConfig>,
  evmClient: EvmClient,
  robotAddress: string,
  performData: Hex,
  label: string,
): string | null {
  if (estimateOnReport(runtime, evmClient, robotAddress, performData, label) === null) return null;
  return writeSignedReport(runtime, evmClient, robotAddress, performData, label);
}

/// Signs `performData` and writes it to the robot, with the DON default gas limit
/// unless `gasLimit` is given. Returns the tx hash, or `null` if the write failed.
export function writeSignedReport<TConfig>(
  runtime: Runtime<TConfig>,
  evmClient: EvmClient,
  robotAddress: string,
  performData: Hex,
  label: string,
  gasLimit?: bigint,
): string | null {
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
      ...(gasLimit === undefined ? {} : {gasConfig: {gasLimit: gasLimit.toString()}}),
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
