import {bytesToHex, cre, getNetwork, handler, type Runtime} from '@chainlink/cre-sdk';
import {
  decodeEventLog,
  encodeAbiParameters,
  parseAbiParameters,
  type Address,
  type Hex,
} from 'viem';

import {IGsmFeeClaimerReceiverABI} from '../../shared/offchain/abi/IGsmFeeClaimerReceiver';
import {
  estimateOnReport,
  MAX_WRITE_GAS,
  shouldSubmit,
  writeSignedReport,
  type EvmClient,
} from '../../shared/offchain/checkUpkeep';
import {type Config, type NetworkConfig, configSchema} from './types';

export {configSchema};

// The receiver holds no target list: the GSMs to probe travel in checkData.
export function encodeGsms(gsms: Address[]): Hex {
  return encodeAbiParameters(parseAbiParameters('address[]'), [gsms]);
}

// A GSM that reverts does not revert the batch (the receiver catches it), so the tx
// receipt is the only place the outcome per GSM is visible.
function logDistributions(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  receiver: Address,
  txHash: string,
  label: string,
): number | null {
  let receipt;
  try {
    receipt = evmClient.getTransactionReceipt(runtime, {hash: txHash}).result().receipt;
  } catch (e) {
    runtime.log(`[${label}] receipt lookup failed for ${txHash}: ${e}`);
    return null;
  }
  if (!receipt) {
    runtime.log(`[${label}] no receipt for ${txHash}`);
    return null;
  }
  let distributed = 0;
  for (const log of receipt.logs) {
    if (bytesToHex(log.address).toLowerCase() !== receiver.toLowerCase()) continue;
    let event;
    try {
      event = decodeEventLog({
        abi: IGsmFeeClaimerReceiverABI,
        topics: log.topics.map((t) => bytesToHex(t)) as [Hex, ...Hex[]],
        data: bytesToHex(log.data),
      });
    } catch {
      continue;
    }
    if (event.eventName === 'FeesDistributed') {
      distributed++;
      runtime.log(`[${label}] FeesDistributed gsm=${event.args.gsm} amount=${event.args.amount}`);
    } else if (event.eventName === 'FeeDistributionFailed') {
      runtime.log(
        `[${label}] FeeDistributionFailed gsm=${event.args.gsm} reason=${event.args.reason}`,
      );
    }
  }
  return distributed;
}

// The estimate only gates the write: a failing GSM is caught on-chain, which makes the
// estimate unreliable as a limit, so the write requests the full CRE quota instead.
export function runForNetwork(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  receiver: Address,
  gsms: Address[],
  label: string,
): string {
  const performData = shouldSubmit(runtime, evmClient, receiver, encodeGsms(gsms), label);
  if (!performData) return 'No fees to distribute';

  const estimate = estimateOnReport(runtime, evmClient, receiver, performData, label);
  if (estimate === null) return 'submit skipped';
  if (estimate > MAX_WRITE_GAS) {
    runtime.log(
      `[${label}] estimate ${estimate} exceeds max write gas ${MAX_WRITE_GAS} — skipping`,
    );
    return 'submit skipped';
  }
  const txHash = writeSignedReport(runtime, evmClient, receiver, performData, label, MAX_WRITE_GAS);
  if (!txHash) return 'submit skipped';

  const distributed = logDistributions(runtime, evmClient, receiver, txHash, label);
  return distributed === null
    ? `submitted, receipt unavailable, tx=${txHash}`
    : `distributed ${distributed}/${gsms.length}, tx=${txHash}`;
}

export const createReceiverHandler = (network: NetworkConfig & {receiver: Address}) => {
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
      return runForNetwork(runtime, evmClient, network.receiver, network.gsms, label);
    } catch (e) {
      runtime.log(`[${label}] failed: ${e}`);
      return 'Processing failed';
    }
  };
};

export const initWorkflow = (config: Config) => {
  const cron = new cre.capabilities.CronCapability();
  return config.evms
    .filter((net): net is NetworkConfig & {receiver: Address} => net.receiver !== '')
    .map((net) => handler(cron.trigger({schedule: config.schedule}), createReceiverHandler(net)));
};
