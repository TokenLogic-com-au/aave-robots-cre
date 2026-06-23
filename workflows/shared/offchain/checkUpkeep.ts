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

type EvmClient = InstanceType<typeof cre.capabilities.EVMClient>;

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
  const onReportCalldata = encodeFunctionData({
    abi: IAaveCREReceiverABI,
    functionName: 'onReport',
    args: ['0x', performData],
  });
  try {
    const estimate = evmClient
      .estimateGas(runtime, {
        msg: encodeCallMsg({from: zeroAddress, to: robotAddress as Hex, data: onReportCalldata}),
      })
      .result();
    runtime.log(`[${label}] estimateGas(onReport) = ${estimate.gas.toString()}`);
  } catch (e) {
    runtime.log(`[${label}] estimateGas failed for onReport — skipping: ${e}`);
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

  const writeResult = evmClient.writeReport(runtime, {receiver: robotAddress, report}).result();

  if (writeResult.txStatus !== TxStatus.SUCCESS) {
    runtime.log(
      `[${label}] writeReport status=${writeResult.txStatus} err=${writeResult.errorMessage ?? ''} — skipping`,
    );
    return null;
  }
  if (!writeResult.txHash) {
    runtime.log(`[${label}] writeReport returned SUCCESS but no txHash — skipping`);
    return null;
  }
  return bytesToHex(writeResult.txHash);
}
