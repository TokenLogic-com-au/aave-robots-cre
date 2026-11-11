// Gas the DON gives a chain write when no gasConfig is sent (the CRE write quota,
// `ChainWrite.EVM.TransactionGasLimit`). Measured on-chain: 10M, except on Ethereum, which
// Chainlink raised to 2^24 in October 2026.
const MAX_WRITE_GAS = 10_000_000n;
const MAX_WRITE_GAS_BY_CHAIN: Readonly<Record<string, bigint>> = {
  'ethereum-mainnet': 16_777_216n,
};

// Forwarder report verification and call overhead on top of `onReport` itself.
const WRITE_OVERHEAD_GAS = 250_000n;

// EIP-150: a CALL passes on at most all but 1/64 of the caller's remaining gas, so the
// forwarder needs `estimate * 64 / 63` for `onReport` to receive its full estimate.
const CALL_GAS_NUMERATOR = 64n;
const CALL_GAS_DENOMINATOR = 63n;

export function maxWriteGas(chainName: string): bigint {
  return MAX_WRITE_GAS_BY_CHAIN[chainName] ?? MAX_WRITE_GAS;
}

/// Whether an `onReport` estimate fits a write on the chain. Anything larger cannot run
/// through CRE and is left to the backup keeper.
export function fitsWriteQuota(chainName: string, estimate: bigint): boolean {
  const required = (estimate * CALL_GAS_NUMERATOR) / CALL_GAS_DENOMINATOR + WRITE_OVERHEAD_GAS;
  return required <= maxWriteGas(chainName);
}
