import {
  bytesToHex,
  cre,
  encodeCallMsg,
  getNetwork,
  handler,
  type Runtime,
} from '@chainlink/cre-sdk';
import {
  decodeAbiParameters,
  decodeEventLog,
  decodeFunctionResult,
  encodeAbiParameters,
  encodeFunctionData,
  parseAbiParameters,
  zeroAddress,
  type Hex,
} from 'viem';
import {shouldSubmit, submitReport} from '../../shared/offchain/checkUpkeep';
import {IHubABI} from '../../shared/offchain/abi/IHub';
import {hubsFor} from '../../shared/offchain/addresses';
import {type Config, type NetworkConfig, type Target, configSchema} from './types';

export {configSchema};

type EvmClient = InstanceType<typeof cre.capabilities.EVMClient>;

type HubAssetPair = {hub: Hex; assetId: bigint};

type MintFeeSharesArgs = {
  assetId: bigint;
  feeReceiver: Hex;
  shares: bigint;
  assets: bigint;
};

type TargetResult = {minted: number; skipped: number; assetCount: bigint};

const ASSET_REF_ARRAY_TYPE = parseAbiParameters('(address hub, uint256 assetId)[]');

function encodePairs(pairs: HubAssetPair[]): Hex {
  return encodeAbiParameters(ASSET_REF_ARRAY_TYPE, [pairs]);
}

function decodePairs(data: Hex): HubAssetPair[] {
  const [pairs] = decodeAbiParameters(ASSET_REF_ARRAY_TYPE, data);
  return pairs as unknown as HubAssetPair[];
}

function readAssetCount(runtime: Runtime<Config>, evmClient: EvmClient, hub: string): bigint {
  const calldata = encodeFunctionData({abi: IHubABI, functionName: 'getAssetCount', args: []});
  const reply = evmClient
    .callContract(runtime, {
      call: encodeCallMsg({from: zeroAddress, to: hub as Hex, data: calldata}),
    })
    .result();
  return decodeFunctionResult({
    abi: IHubABI,
    functionName: 'getAssetCount',
    data: bytesToHex(reply.data),
  }) as bigint;
}

function findMintFeeSharesEvents(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  txHash: string,
  hub: string,
): Map<string, MintFeeSharesArgs> {
  const events = new Map<string, MintFeeSharesArgs>();
  const {receipt} = evmClient.getTransactionReceipt(runtime, {hash: txHash}).result();
  if (!receipt) return events;

  const hubLower = hub.toLowerCase();
  for (const log of receipt.logs) {
    const logAddr = bytesToHex(log.address).toLowerCase();
    if (logAddr !== hubLower) continue;
    try {
      const decoded = decodeEventLog({
        abi: IHubABI,
        topics: log.topics.map((t) => bytesToHex(t)) as [Hex, ...Hex[]],
        data: bytesToHex(log.data),
      });
      if (decoded.eventName === 'MintFeeShares') {
        const args = decoded.args as unknown as MintFeeSharesArgs;
        events.set(args.assetId.toString(), args);
      }
    } catch {
      // log doesn't match any event in IHubABI — skip
    }
  }
  return events;
}

export function runForTarget(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  network: NetworkConfig,
  target: Target,
): TargetResult {
  const label = `${network.chainName}:${target.hub}`;
  runtime.log(`[${label}] tick (minter=${target.minter})`);

  const assetCount = readAssetCount(runtime, evmClient, target.hub);
  runtime.log(`[${label}] assetCount=${assetCount}`);
  if (assetCount === 0n) {
    return {minted: 0, skipped: 0, assetCount};
  }

  const allPairs: HubAssetPair[] = [];
  for (let assetId = 0n; assetId < assetCount; assetId++) {
    allPairs.push({hub: target.hub as Hex, assetId});
  }

  const performData = shouldSubmit(runtime, evmClient, target.minter, encodePairs(allPairs), label);
  if (!performData) {
    return {minted: 0, skipped: Number(assetCount), assetCount};
  }

  const mintablePairs = decodePairs(performData);
  runtime.log(`[${label}] mintable=${mintablePairs.length}/${assetCount}`);

  const txHash = submitReport(runtime, evmClient, target.minter, performData, label);
  if (!txHash) {
    return {minted: 0, skipped: Number(assetCount), assetCount};
  }

  const events = findMintFeeSharesEvents(runtime, evmClient, txHash, target.hub);
  for (const pair of mintablePairs) {
    const sublabel = `${label}:asset=${pair.assetId}`;
    const event = events.get(pair.assetId.toString());
    if (event) {
      runtime.log(
        `[${sublabel}] MintFeeShares` +
          ` | feeReceiver=${event.feeReceiver}` +
          ` | shares=${event.shares}` +
          ` | assets=${event.assets}` +
          ` | tx=${txHash}`,
      );
    } else {
      runtime.log(`[${sublabel}] in mintable set but no MintFeeShares event found in tx ${txHash}`);
    }
  }

  const minted = events.size;
  return {minted, skipped: Number(assetCount) - minted, assetCount};
}

export const createTargetHandler = (network: NetworkConfig, target: Target) => {
  return (runtime: Runtime<Config>): string => {
    const label = `${network.chainName}:${target.hub}`;
    const cre_network = getNetwork({
      chainFamily: 'evm',
      chainSelectorName: network.chainName,
      isTestnet: network.isTestnet,
    });
    if (!cre_network) {
      runtime.log(`[${label}] network not found — skipping`);
      return 'Network not found';
    }
    const evmClient = new cre.capabilities.EVMClient(cre_network.chainSelector.selector);

    try {
      const res = runForTarget(runtime, evmClient, network, target);
      return `evaluated ${res.assetCount} assets, minted ${res.minted}, skipped ${res.skipped}`;
    } catch (e) {
      runtime.log(`[${label}] failed: ${e}`);
      return 'Processing failed';
    }
  };
};

export const initWorkflow = (config: Config) => {
  const cron = new cre.capabilities.CronCapability();
  return config.evms
    .filter((net) => net.chainName && net.minter)
    .flatMap((net) =>
      hubsFor(net.chainName).map((hub) =>
        handler(
          cron.trigger({schedule: config.schedule}),
          createTargetHandler(net, {minter: net.minter, hub}),
        ),
      ),
    );
};
