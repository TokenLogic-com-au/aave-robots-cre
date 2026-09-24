// USD values carry the oracle's 8 decimals.
export function formatUsd(rawUsd: bigint): string {
  const dollars = rawUsd / 100_000_000n;
  const cents = (rawUsd % 100_000_000n) / 1_000_000n;
  const dollarsStr = dollars.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return `$${dollarsStr}.${cents.toString().padStart(2, '0')}`;
}
