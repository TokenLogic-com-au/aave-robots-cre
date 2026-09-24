// Aave V3 PoolDataProvider ABI (exact match from DataProviderV3.json)
export const IAaveDataProviderV3 = [
  {
    inputs: [],
    name: 'getAllReservesTokens',
    outputs: [
      {
        components: [
          {internalType: 'string', name: 'symbol', type: 'string'},
          {internalType: 'address', name: 'tokenAddress', type: 'address'},
        ],
        internalType: 'struct IPoolDataProvider.TokenData[]',
        name: '',
        type: 'tuple[]',
      },
    ],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [{internalType: 'address', name: 'asset', type: 'address'}],
    name: 'getReserveConfigurationData',
    outputs: [
      {internalType: 'uint256', name: 'decimals', type: 'uint256'},
      {internalType: 'uint256', name: 'ltv', type: 'uint256'},
      {
        internalType: 'uint256',
        name: 'liquidationThreshold',
        type: 'uint256',
      },
      {internalType: 'uint256', name: 'liquidationBonus', type: 'uint256'},
      {internalType: 'uint256', name: 'reserveFactor', type: 'uint256'},
      {internalType: 'bool', name: 'usageAsCollateralEnabled', type: 'bool'},
      {internalType: 'bool', name: 'borrowingEnabled', type: 'bool'},
      {internalType: 'bool', name: 'stableBorrowRateEnabled', type: 'bool'},
      {internalType: 'bool', name: 'isActive', type: 'bool'},
      {internalType: 'bool', name: 'isFrozen', type: 'bool'},
    ],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [{internalType: 'address', name: 'asset', type: 'address'}],
    name: 'getReserveCaps',
    outputs: [
      {internalType: 'uint256', name: 'borrowCap', type: 'uint256'},
      {internalType: 'uint256', name: 'supplyCap', type: 'uint256'},
    ],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [{internalType: 'address', name: 'asset', type: 'address'}],
    name: 'getReserveTokensAddresses',
    outputs: [
      {internalType: 'address', name: 'aTokenAddress', type: 'address'},
      {
        internalType: 'address',
        name: 'stableDebtTokenAddress',
        type: 'address',
      },
      {
        internalType: 'address',
        name: 'variableDebtTokenAddress',
        type: 'address',
      },
    ],
    stateMutability: 'view',
    type: 'function',
  },
] as const;
