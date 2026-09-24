// Aave PriceOracle ABI — prices returned in USD with 8 decimals
// https://docs.aave.com/developers/core-contracts/aaveoracle
export const IAavePriceOracle = [
  {
    inputs: [{internalType: 'address[]', name: 'assets', type: 'address[]'}],
    name: 'getAssetsPrices',
    outputs: [{internalType: 'uint256[]', name: '', type: 'uint256[]'}],
    stateMutability: 'view',
    type: 'function',
  },
] as const;
