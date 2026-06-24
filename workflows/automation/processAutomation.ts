import {
  bytesToHex,
  cre,
  encodeCallMsg,
  hexToBase64,
  TxStatus,
  type Runtime,
} from '@chainlink/cre-sdk';
import {
  encodeFunctionData,
  decodeFunctionResult,
  zeroAddress,
  encodeAbiParameters,
  parseAbiParameters,
  type Hex,
} from 'viem';
import {ICLAutomation} from '../contracts/abi/ICLAutomation';
import {IMailboxCRE} from '../contracts/abi/IMailboxCRE';
import {type Config} from './types';

export const processAutomation = (
  runtime: Runtime<Config>,
  evmClient: InstanceType<typeof cre.capabilities.EVMClient>,
  automationAddress: string,
  mailboxAddress: string,
  chainName: string,
  checkData: string,
  name?: string,
): string | null => {
  const robot = name ? `${name} (${automationAddress})` : automationAddress;
  const checkUpkeepCalldata = encodeFunctionData({
    abi: ICLAutomation,
    functionName: 'checkUpkeep',
    args: [checkData as Hex],
  });
  const checkUpkeepCall = evmClient
    .callContract(runtime, {
      call: encodeCallMsg({
        from: zeroAddress,
        to: automationAddress as Hex,
        data: checkUpkeepCalldata,
      }),
    })
    .result();
  const checkUpkeepData = bytesToHex(checkUpkeepCall.data);
  if (checkUpkeepData === '0x') {
    runtime.log(`[${chainName}] [${robot}] checkUpkeep returned empty data, skipping`);
    return null;
  }

  const checkUpkeepResult = decodeFunctionResult({
    abi: ICLAutomation,
    functionName: 'checkUpkeep',
    data: checkUpkeepData,
  });
  runtime.log(`[${chainName}] [${robot}] checkUpkeep: ${checkUpkeepResult[0]}`);

  if (!checkUpkeepResult[0]) return null;

  const mailboxPayload = encodeFunctionData({
    abi: ICLAutomation,
    functionName: 'performUpkeep',
    args: [checkUpkeepResult[1]],
  });
  const mailboxReportData = encodeAbiParameters(parseAbiParameters('address, bytes'), [
    automationAddress as Hex,
    mailboxPayload,
  ]);
  const onReportCalldata = encodeFunctionData({
    abi: IMailboxCRE,
    functionName: 'onReport',
    args: ['0x', mailboxReportData],
  });

  try {
    const estimateGasResult = evmClient
      .estimateGas(runtime, {
        msg: encodeCallMsg({
          from: zeroAddress,
          to: mailboxAddress as Hex,
          data: onReportCalldata,
        }),
      })
      .result();
    runtime.log(
      `[${chainName}] [${robot}] estimate gas (performUpkeep via onReport): ${estimateGasResult.gas.toString()}`,
    );
  } catch (e) {
    runtime.log(`[${chainName}] [${robot}] estimate gas failed (performUpkeep via onReport): ${e}`);
    return null;
  }

  const reportResponse = runtime
    .report({
      encodedPayload: hexToBase64(mailboxReportData),
      encoderName: 'evm',
      signingAlgo: 'ecdsa',
      hashingAlgo: 'keccak256',
    })
    .result();
  const writeReportResult = evmClient
    .writeReport(runtime, {
      receiver: mailboxAddress,
      report: reportResponse,
    })
    .result();

  if (writeReportResult.txStatus !== TxStatus.SUCCESS) {
    runtime.log(
      `[${chainName}] [${robot}] writeReport status=${writeReportResult.txStatus} err=${writeReportResult.errorMessage ?? ''} - skipping`,
    );
    return null;
  }
  if (!writeReportResult.txHash) {
    runtime.log(`[${chainName}] [${robot}] writeReport returned SUCCESS but no txHash - skipping`);
    return null;
  }
  const txHash = bytesToHex(writeReportResult.txHash);

  runtime.log(`[${chainName}] [${robot}] tx: ${txHash}`);
  return txHash;
};
