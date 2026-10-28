// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @dev Aave V2 ProtocolDataProvider reads the workflow uses; the address book's V2 interface
/// has no `getReserveData`.
interface IAaveProtocolDataProviderV2 {
  function getReserveData(
    address asset
  )
    external
    view
    returns (
      uint256 availableLiquidity,
      uint256 totalStableDebt,
      uint256 totalVariableDebt,
      uint256 liquidityRate,
      uint256 variableBorrowRate,
      uint256 stableBorrowRate,
      uint256 averageStableBorrowRate,
      uint256 liquidityIndex,
      uint256 variableBorrowIndex,
      uint40 lastUpdateTimestamp
    );

  function getReserveTokensAddresses(
    address asset
  )
    external
    view
    returns (
      address aTokenAddress,
      address stableDebtTokenAddress,
      address variableDebtTokenAddress
    );
}
