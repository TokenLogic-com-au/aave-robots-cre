import type {Runtime} from '@chainlink/cre-sdk';
import {encodeFunctionData, type Hex} from 'viem';
import {ISteward} from '../abi/ISteward';
import {applySupplyCapAdjustment, type SupplyCaps} from './caps';
import {destinationPool, type ChainConfig} from './config';
import {calculateUsdValue} from './math';
import {formatUsd} from './format';
import type {ActiveReserve} from './reserves';

export type StewardContext = {
  runtime: Runtime<unknown>;
  chain: ChainConfig;
  caps: SupplyCaps;
  primeTokens: Set<string>;
};

// Caps `amount` to the V3 supply cap, drops it if it falls under `minUsd`, and encodes
// the Steward call into the destination pool. Shared tail of deposits and migrations.
export function stewardCall(
  ctx: StewardContext,
  reserve: ActiveReserve,
  amount: bigint,
  minUsd: bigint,
  operation: 'deposit' | 'migration',
): Hex | null {
  const {runtime, chain, caps, primeTokens} = ctx;
  const {key, token, price} = reserve;
  const {decimals} = reserve.config;

  const capped = applySupplyCapAdjustment(runtime, amount, key, decimals, caps.get(key), operation);
  if (capped === null) return null;

  const usd = calculateUsdValue(capped, price, decimals);
  if (usd < minUsd) {
    runtime.log(`  Skip ${operation} ${key}: amount below min USD after cap adjustment`);
    return null;
  }

  const {pool, label} = destinationPool(key, chain, primeTokens);
  if (operation === 'deposit') {
    runtime.log(`  -> Deposit ${formatUsd(usd)} of ${key} into ${label} pool`);
    return encodeFunctionData({
      abi: ISteward,
      functionName: 'depositV3',
      args: [pool, token, capped],
    });
  }
  runtime.log(`  -> Migrate ${formatUsd(usd)} of ${key} V2 -> V3 ${label} pool`);
  return encodeFunctionData({
    abi: ISteward,
    functionName: 'migrateV2toV3',
    args: [chain.v2!.corePool, pool, token, capped],
  });
}
