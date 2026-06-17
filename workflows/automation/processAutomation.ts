import { bytesToHex, cre, encodeCallMsg, hexToBase64, type Runtime } from '@chainlink/cre-sdk';
import { encodeFunctionData, decodeFunctionResult, zeroAddress, encodeAbiParameters, parseAbiParameters, type Hex } from 'viem';
import { ICLAutomation } from '../contracts/abi/ICLAutomation';
import { IMailboxCRE } from '../contracts/abi/IMailboxCRE';
import { type Config, type AutomationContractType } from './types';

export const processAutomation = (
  runtime: Runtime<Config>,
  evmClient: InstanceType<typeof cre.capabilities.EVMClient>,
  automationAddress: string,
  mailboxAddress: string,
  chainName: string,
  checkData: string,
  automationContractType: AutomationContractType
): string | null => {
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
    runtime.log(`[${chainName}] checkUpkeep(${automationAddress}): call returned empty data, skipping`);
    return null;
  }

  const checkUpkeepResult = decodeFunctionResult({
    abi: ICLAutomation,
    functionName: 'checkUpkeep',
    data: checkUpkeepData,
  });
  runtime.log(`[${chainName}] checkUpkeep(${automationAddress}): ${checkUpkeepResult[0]}`);

  if (!checkUpkeepResult[0]) return null;

  // mailbox is the intermediary contract, which forwards the call to our automation robot contract in order to perform on-chain write
  // in chainlink automation contract, checkUpkeep method returns the checkData which is not encoded with function selector and in gelato automation
  // contract, the checkUpkeep method returns the bytes encoded data, hence here we skip encoding when the automation contract type is gelato
  const mailboxPayload =
    automationContractType === 'chainlink'
      ? encodeFunctionData({
          abi: ICLAutomation,
          functionName: 'performUpkeep',
          args: [checkUpkeepResult[1]],
        })
      : checkUpkeepResult[1];
  const mailboxReportData = encodeAbiParameters(
    parseAbiParameters('address, bytes'),
    [automationAddress as Hex, mailboxPayload]
  );
  const onReportCalldata = encodeFunctionData({
    abi: IMailboxCRE,
    functionName: 'onReport',
    args: ['0x', mailboxReportData],
  });

  // we estimate-gas before performing on-chain write, so in case where tx is failing in simulation we do not write on-chain and skip the execution
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
    runtime.log(`[${chainName}] estimate gas for performUpkeep via onReport(${automationAddress}): ${estimateGasResult.gas.toString()}`);
  } catch (e) {
    runtime.log(`[${chainName}] estimate gas failed for performUpkeep via onReport(${automationAddress}): ${e}`);
    return null;
  }

  // sign and send the on-chain write to the mailbox contract, which forwards write to the automation contract
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

  if (!writeReportResult.txHash) throw new Error(`[${chainName}] writeReport returned invalid txHash`);
  const txHash = bytesToHex(writeReportResult.txHash);

  runtime.log(`[${chainName}] tx: ${txHash}`);
  return txHash;
};
