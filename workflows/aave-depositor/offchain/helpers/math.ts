import {BPS} from '../types';

export function applyBps(amount: bigint, bps: bigint): bigint {
  return (amount * bps) / BPS;
}

// Prices come from the Aave oracle with 8 decimals, so USD values do too.
export function calculateUsdValue(balance: bigint, price: bigint, decimals: bigint): bigint {
  return (price * balance) / 10n ** decimals;
}
