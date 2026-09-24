import type {Hex} from 'viem';
import {applyBps, calculateUsdValue} from './math';
import {isActive, type ActiveReserve, type Reserve} from './reserves';
import {stewardCall, type StewardContext} from './steward';

export function migrationCandidates(
  reserves: Reserve[],
  ignoredTokens: Set<string>,
): ActiveReserve[] {
  return reserves.filter(
    (r): r is ActiveReserve =>
      !ignoredTokens.has(r.key) && isActive(r) && r.v2AToken !== null && r.v2Balance > 0n,
  );
}

// Migrates `migrationBps` of the V2 aToken balance, bounded by V2 liquidity and the V3 cap.
export function buildMigrationCalls(
  ctx: StewardContext,
  candidates: ActiveReserve[],
  migrationMinUsd: bigint,
  migrationBps: bigint,
): Hex[] {
  if (!ctx.chain.v2) return [];
  return candidates.flatMap((r) => {
    if (r.v2Liquidity === null) return [];
    const amount = applyBps(
      r.v2Balance < r.v2Liquidity ? r.v2Balance : r.v2Liquidity,
      migrationBps,
    );
    if (amount === 0n) return [];
    if (calculateUsdValue(amount, r.price, r.config.decimals) < migrationMinUsd) return [];
    return stewardCall(ctx, r, amount, migrationMinUsd, 'migration') ?? [];
  });
}
