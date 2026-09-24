import {cre, handler, type Runtime} from '@chainlink/cre-sdk';
import {
  decodeFunctionResult,
  encodeAbiParameters,
  encodeFunctionData,
  parseAbiParameters,
  type Address,
  type Hex,
} from 'viem';

import {
  estimateOnReport,
  MAX_WRITE_GAS,
  shouldSubmit,
  writeSignedReport,
} from '../../shared/offchain/checkUpkeep';
import {type Config, type EvmClient, type Result, configSchema} from './types';
import {IAaveDepositorReceiver} from './abi/IAaveDepositorReceiver';
import {fetchSupplyCaps} from './helpers/caps';
import {parseChainConfig, toTokenSet} from './helpers/config';
import {buildDepositCalls, depositCandidates} from './helpers/deposits';
import {buildMigrationCalls, migrationCandidates} from './helpers/migrations';
import {decodeOrNull, multicall} from './helpers/multicall';
import {fetchReserves} from './helpers/reserves';
import type {StewardContext} from './helpers/steward';

export {configSchema};

// A V2 to V3 migration costs ~750k gas through Roles + Safe + Steward (a deposit ~300k),
// and a CRE write is capped at MAX_WRITE_GAS, so calls are written in batches of at most this size.
export const MAX_CALLS_PER_REPORT = 8;
// CRE allows 15 chain reads per execution: 8 go to reserves and caps, 1 to the receiver,
// and each report batch spends 2 (checkUpkeep + estimateGas). The rest waits for the next tick.
export const MAX_REPORTS_PER_RUN = 3;

type ReceiverInfo = {forwarder: Address; expectedWorkflowId: Hex};

export function encodeCalls(calls: Hex[]): Hex {
  return encodeAbiParameters(parseAbiParameters('bytes[]'), [calls]);
}

export function chunkCalls(calls: Hex[]): Hex[][] {
  const chunks: Hex[][] = [];
  for (let i = 0; i < calls.length; i += MAX_CALLS_PER_REPORT) {
    chunks.push(calls.slice(i, i + MAX_CALLS_PER_REPORT));
  }
  return chunks;
}

// onReport only accepts the forwarder, so the gas estimate has to impersonate it and
// carry the pinned workflow id (if any) as report metadata. Read at latest, like
// checkUpkeep, so a freshly deployed or re-pinned receiver is seen right away.
function readReceiver(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  receiver: Address,
): Result<ReceiverInfo> {
  const res = multicall(
    runtime,
    evmClient,
    [
      {
        target: receiver,
        callData: encodeFunctionData({abi: IAaveDepositorReceiver, functionName: 'FORWARDER'}),
      },
      {
        target: receiver,
        callData: encodeFunctionData({
          abi: IAaveDepositorReceiver,
          functionName: 'expectedWorkflowId',
        }),
      },
    ],
    'latest',
  );
  if (!res.ok) return res;
  const forwarder = decodeOrNull(res.value[0], (data) =>
    decodeFunctionResult({abi: IAaveDepositorReceiver, functionName: 'FORWARDER', data}),
  );
  const expectedWorkflowId = decodeOrNull(res.value[1], (data) =>
    decodeFunctionResult({abi: IAaveDepositorReceiver, functionName: 'expectedWorkflowId', data}),
  );
  if (forwarder === null || expectedWorkflowId === null) {
    return {ok: false, error: 'receiver returned no forwarder / workflow id'};
  }
  return {ok: true, value: {forwarder, expectedWorkflowId}};
}

// The estimate impersonates the forwarder with the pinned workflow id as metadata, and
// only gates the write (revert, or batch over the quota); the write requests the full quota.
export function submitCalls(
  runtime: Runtime<Config>,
  evmClient: EvmClient,
  receiver: Address,
  info: ReceiverInfo,
  performData: Hex,
  label: string,
): string | null {
  const estimate = estimateOnReport(runtime, evmClient, receiver, performData, label, {
    from: info.forwarder,
    metadata: info.expectedWorkflowId,
  });
  if (estimate === null) return null;
  if (estimate > MAX_WRITE_GAS) {
    runtime.log(
      `[${label}] estimate ${estimate} exceeds max write gas ${MAX_WRITE_GAS} — skipping`,
    );
    return null;
  }
  return writeSignedReport(runtime, evmClient, receiver, performData, label, MAX_WRITE_GAS);
}

export const onCronTrigger = (runtime: Runtime<Config>): string => {
  const config = runtime.config;
  const chain = parseChainConfig(config);
  if (chain === null) {
    runtime.log(`network not found or receiver unset: ${config.chainName}`);
    return 'Network not found';
  }
  const label = `${chain.chainName}:${chain.receiver}`;
  const ignoredTokens = toTokenSet(config.ignoredTokens);

  runtime.log(`[${label}] collector ${chain.collector}`);
  const evmClient = new cre.capabilities.EVMClient(chain.chainSelector);

  const reservesRes = fetchReserves(runtime, evmClient, chain);
  if (!reservesRes.ok) {
    runtime.log(`  Failed to read reserves: ${reservesRes.error}`);
    return 'No calls to execute';
  }
  const reserves = reservesRes.value;
  if (reserves.length === 0) {
    runtime.log('  No reserves found');
    return 'No calls to execute';
  }
  runtime.log(`  Found ${reserves.length} reserves`);

  const ctx: StewardContext = {
    runtime,
    chain,
    caps: new Map(),
    primeTokens: toTokenSet(config.primeTokens),
  };
  const deposits = depositCandidates(ctx, reserves, ignoredTokens, config.depositMinUsd);
  const migrations = migrationCandidates(reserves, ignoredTokens);
  const capsRes = fetchSupplyCaps(runtime, evmClient, chain.dataProviderV3, [
    ...new Set([...deposits, ...migrations].map((r) => r.token)),
  ]);
  if (!capsRes.ok) {
    runtime.log(`  Failed to read supply caps: ${capsRes.error}`);
    return 'No calls to execute';
  }
  ctx.caps = capsRes.value;

  const depositCalls = buildDepositCalls(ctx, deposits, config.depositMinUsd);
  const migrationCalls = buildMigrationCalls(
    ctx,
    migrations,
    config.migrationMinUsd,
    config.migrationBps,
  );
  const calls = [...depositCalls, ...migrationCalls];
  if (calls.length === 0) {
    runtime.log(`  No calls to execute on ${chain.chainName}`);
    return 'No calls to execute';
  }
  runtime.log(
    `  ${depositCalls.length} deposit(s) + ${migrationCalls.length} migration(s) on ${chain.chainName}`,
  );

  const infoRes = readReceiver(runtime, evmClient, chain.receiver);
  if (!infoRes.ok) {
    runtime.log(`[${label}] failed to read receiver — skipping: ${infoRes.error}`);
    return 'submit skipped';
  }

  const chunks = chunkCalls(calls);
  const deferred = chunks.splice(MAX_REPORTS_PER_RUN);
  if (deferred.length > 0) {
    runtime.log(`  ${deferred.flat().length} call(s) deferred to the next tick`);
  }
  const txHashes: string[] = [];
  let skipped = 0;
  for (const chunk of chunks) {
    const performData = shouldSubmit(runtime, evmClient, chain.receiver, encodeCalls(chunk), label);
    const txHash = performData
      ? submitCalls(runtime, evmClient, chain.receiver, infoRes.value, performData, label)
      : null;
    if (txHash) txHashes.push(txHash);
    else skipped++;
  }
  if (txHashes.length === 0) return 'submit skipped';
  return `${txHashes.length} report(s) submitted${skipped ? `, ${skipped} skipped` : ''}, tx=${txHashes.join(',')}`;
};

export const initWorkflow = (config: Config) => {
  if (!config.receiver) return [];
  const cron = new cre.capabilities.CronCapability();
  return [handler(cron.trigger({schedule: config.schedule}), onCronTrigger)];
};
