import type {Hex} from 'viem';
import {calculateUsdValue} from './math';
import {formatUsd} from './format';
import {isActive, type ActiveReserve, type Reserve} from './reserves';
import {stewardCall, type StewardContext} from './steward';

export function depositCandidates(
  ctx: StewardContext,
  reserves: Reserve[],
  ignoredTokens: Set<string>,
  depositMinUsd: bigint,
): ActiveReserve[] {
  const candidates: ActiveReserve[] = [];
  let skippedIgnored = 0;
  let skippedInactive = 0;
  let skippedNoBalance = 0;
  let skippedBelowMin = 0;
  let totalIdleUsd = 0n;

  for (const r of reserves) {
    if (ignoredTokens.has(r.key)) {
      skippedIgnored++;
      continue;
    }
    if (!isActive(r)) {
      skippedInactive++;
      continue;
    }
    if (r.balance === 0n) {
      skippedNoBalance++;
      continue;
    }
    const usdValue = calculateUsdValue(r.balance, r.price, r.config.decimals);
    totalIdleUsd += usdValue;
    if (usdValue < depositMinUsd) {
      skippedBelowMin++;
      continue;
    }
    candidates.push(r);
  }

  ctx.runtime.log(
    `  Collector idle value: ${formatUsd(totalIdleUsd)} across ${reserves.length} tokens` +
      ` (ignored=${skippedIgnored} inactive=${skippedInactive} no-balance=${skippedNoBalance} below-min=${skippedBelowMin} eligible=${candidates.length})`,
  );
  return candidates;
}

export function buildDepositCalls(
  ctx: StewardContext,
  candidates: ActiveReserve[],
  depositMinUsd: bigint,
): Hex[] {
  return candidates.flatMap((r) => stewardCall(ctx, r, r.balance, depositMinUsd, 'deposit') ?? []);
}
