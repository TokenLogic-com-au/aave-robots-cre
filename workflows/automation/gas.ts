// Gas the DON attaches to every chain write when no gasConfig is sent (the platform's
// ChainWrite.EVM gas quota for our workflows). Measured on-chain: 10M until 2026-10-04,
// 16,777,216 from 2026-10-07 after Chainlink raised it. Anything estimated above it
// cannot be executed through CRE and is left to the backup keeper.
export const MAX_WRITE_GAS_LIMIT = 16_777_216n;
