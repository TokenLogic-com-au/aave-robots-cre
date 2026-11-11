import type {Hex} from 'viem';

// Gas quota of a CRE write (`ChainWrite.EVM.TransactionGasLimit`): the gas limit the DON gives
// our writes, which send none. Measured on-chain: 10M, except on Ethereum, which Chainlink raised
// to 2^24 in October 2026. `submitReport` skips writes whose estimate doesn't fit.
export const MAX_WRITE_GAS = 10_000_000n;
export const MAX_WRITE_GAS_BY_CHAIN: Readonly<Record<string, bigint>> = {
  'ethereum-mainnet': 16_777_216n,
};

// Forwarder report verification and call overhead on top of `onReport` itself.
export const WRITE_OVERHEAD_GAS = 250_000n;

// EIP-150: a CALL passes on at most all but 1/64 of the caller's remaining gas, so the
// forwarder needs `estimate * 64 / 63` for `onReport` to receive its full estimate.
export const CALL_GAS_NUMERATOR = 64n;
export const CALL_GAS_DENOMINATOR = 63n;

// For robots whose receiver holds its own targets and takes no `checkData`.
export const EMPTY_CHECK_DATA: Hex = '0x';

// CRE cron schedules (seconds field first).
export const EVERY_10_MINUTES = '0 */10 * * * *';
export const GOVERNANCE_SCHEDULE = EVERY_10_MINUTES;
