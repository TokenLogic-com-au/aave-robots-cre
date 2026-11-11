// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IWorkflowsBase} from 'aave-cre/IWorkflowsBase.sol';

/// @title IMintToTreasuryReceiver
/// @notice Robot that calls `IPool.mintToTreasury` on Aave v3 pools once the USD value of the
/// reserve factor accrued to the treasury crosses an owner-configured per-pool threshold.
/// @dev `checkData` and `report` are both `abi.encode(address[] pools)`.
interface IMintToTreasuryReceiver is IWorkflowsBase {
  struct PoolThreshold {
    address pool;
    uint256 usdThreshold;
  }

  /// @notice Emitted when the USD threshold of a pool is updated.
  /// @param pool Pool the threshold applies to.
  /// @param usdThreshold New threshold, in the pool oracle's base currency units (1e8 = $1).
  event UsdThresholdUpdated(address indexed pool, uint256 usdThreshold);

  /// @notice Thrown when `canMint` is queried for a pool with no threshold set.
  /// @param pool Pool queried.
  error NotConfigured(address pool);

  /// @notice Thrown when `onReport` runs but no pool in the batch was mintable.
  error ConditionsNotMet();

  /// @notice Thrown when a threshold is set to 0 or `DISABLED_THRESHOLD`.
  /// @param usdThreshold Rejected value.
  error InvalidUsdThreshold(uint256 usdThreshold);

  /// @notice Set the USD threshold of a pool. Owner only.
  /// @param pool Pool the threshold applies to.
  /// @param usdThreshold Threshold in the pool oracle's base currency units, in
  /// `(0, DISABLED_THRESHOLD)`.
  function updateUsdThreshold(address pool, uint256 usdThreshold) external;

  /// @notice Disable minting for a pool. Owner or guardian.
  /// @param pool Pool to disable.
  function disableMinting(address pool) external;

  /// @notice Returns the USD threshold of a pool (0 when not configured).
  /// @param pool Pool queried.
  function getUsdThreshold(address pool) external view returns (uint256);

  /// @notice Returns the value of the amounts accrued to the treasury on every active reserve of
  /// the pool, in the pool oracle's base currency units. Reserves whose price is unavailable
  /// count as 0.
  /// @param pool Pool queried.
  function getAccruedUsd(address pool) external view returns (uint256);

  /// @notice Returns whether `onReport` would mint to the treasury on a pool.
  /// @param pool Pool to evaluate.
  function canMint(address pool) external view returns (bool);

  /// @notice The sentinel value used to disable minting for a pool.
  function DISABLED_THRESHOLD() external pure returns (uint256);
}
