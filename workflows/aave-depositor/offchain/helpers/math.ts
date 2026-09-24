import {BPS} from '../types';

export function applyBps(amount: bigint, bps: bigint): bigint {
  return (amount * bps) / BPS;
}

// Prices come from the Aave oracle with 8 decimals, so USD values do too.
export function calculateUsdValue(balance: bigint, price: bigint, decimals: bigint): bigint {
  return (price * balance) / 10n ** decimals;
}

export function formatUsd(rawUsd: bigint): string {
  const dollars = rawUsd / 100_000_000n;
  const cents = (rawUsd % 100_000_000n) / 1_000_000n;
  const dollarsStr = dollars.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return `$${dollarsStr}.${cents.toString().padStart(2, '0')}`;
}
