import type {Runtime} from '@chainlink/cre-sdk';
import type {Address} from 'viem';
import type {EvmClient, Result} from '../types';
import {applyBps} from './math';
import {decodeOrNull, multicall} from './multicall';
import {calls, decode} from './reads';

const SUPPLY_CAP_SAFETY_BPS = 9_500n;

export type SupplyCap = {supplyCap: bigint; aToken: Address | null; totalSupply: bigint | null};
export type SupplyCaps = Map<string, SupplyCap>;

// Two chain reads: caps + aToken addresses for `tokens`, then totalSupply of the capped aTokens.
export function fetchSupplyCaps(
  runtime: Runtime<unknown>,
  evmClient: EvmClient,
  dataProviderV3: Address,
  tokens: Address[],
): Result<SupplyCaps> {
  const caps: SupplyCaps = new Map();
  if (tokens.length === 0) return {ok: true, value: caps};

  const capsAndATokens = multicall(runtime, evmClient, [
    ...tokens.map((t) => calls.reserveCaps(dataProviderV3, t)),
    ...tokens.map((t) => calls.reserveAToken(dataProviderV3, t)),
  ]);
  if (!capsAndATokens.ok) return capsAndATokens;
  for (const [i, token] of tokens.entries()) {
    caps.set(token.toLowerCase(), {
      supplyCap: decodeOrNull(capsAndATokens.value[i], decode.supplyCap) ?? 0n,
      aToken: decodeOrNull(capsAndATokens.value[tokens.length + i], decode.aToken),
      totalSupply: null,
    });
  }

  const capped = [...caps.values()].filter(
    (c): c is SupplyCap & {aToken: Address} => c.supplyCap > 0n && c.aToken !== null,
  );
  const supplies = multicall(
    runtime,
    evmClient,
    capped.map((c) => calls.totalSupply(c.aToken)),
  );
  if (!supplies.ok) return supplies;
  for (const [i, cap] of capped.entries()) {
    cap.totalSupply = decodeOrNull(supplies.value[i], decode.uint);
  }
  return {ok: true, value: caps};
}

// Keeps `amount` within 95% of the room left under the supply cap; null means skip.
export function applySupplyCapAdjustment(
  runtime: Runtime<unknown>,
  amount: bigint,
  key: string,
  decimals: bigint,
  cap: SupplyCap | undefined,
  operation: 'deposit' | 'migration',
): bigint | null {
  if (!cap || cap.supplyCap === 0n) return amount;
  if (cap.aToken === null) {
    runtime.log(`  Skip ${operation} ${key}: aToken address is zero`);
    return null;
  }
  if (cap.totalSupply === null) {
    runtime.log(`  Skip ${operation} ${key}: could not fetch aToken totalSupply`);
    return null;
  }

  const normalizedCap = cap.supplyCap * 10n ** decimals;
  const rawRoom = normalizedCap > cap.totalSupply ? normalizedCap - cap.totalSupply : 0n;
  const roomLeft = applyBps(rawRoom, SUPPLY_CAP_SAFETY_BPS);

  if (roomLeft === 0n) {
    runtime.log(`  Skip ${operation} ${key}: supply cap reached (or <5% room)`);
    return null;
  }
  if (roomLeft < amount) {
    runtime.log(`  Adjusting ${key} ${operation}: ${amount} -> ${roomLeft} (supply cap 95%)`);
    return roomLeft;
  }
  return amount;
}
