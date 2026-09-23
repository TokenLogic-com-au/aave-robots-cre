// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

/// @notice Minimal view of a GHO GSM (Gho Stability Module) fee surface.
interface IGsmFees {
  /// @notice Fees accrued by the GSM and not yet sent to the GHO treasury.
  function getAccruedFees() external view returns (uint256);

  /// @notice Sends the accrued fees to the GHO treasury. Permissionless.
  function distributeFeesToTreasury() external;
}

/// @title IGsmFeeClaimerReceiver
/// @notice Robot that pushes accrued GSM fees to the GHO treasury. Native CRE
/// re-implementation of the `bot-gsm-fee-claimer` workflow and its `GsmFeeDistributor`.
/// @dev `checkData` is `abi.encode(address[] gsms)`. `checkUpkeep` returns the subset
/// with accrued fees, `abi.encode(address[])`, which the workflow signs and passes as
/// `report`.
interface IGsmFeeClaimerReceiver is IAaveCREReceiver {
  /// @notice Emitted when a GSM's accrued fees are sent to the treasury.
  /// @param gsm The GSM whose fees were distributed.
  /// @param amount The fees the GSM reported right before distributing.
  event FeesDistributed(address indexed gsm, uint256 amount);

  /// @notice Emitted when a GSM's distribution reverted. The rest of the batch still runs.
  /// @param gsm The GSM whose distribution failed.
  event FeeDistributionFailed(address indexed gsm);

  /// @notice Emitted when the robot is excluded from / included in automation.
  /// @param disabled Whether the robot is now excluded from automation.
  event AutomationDisabled(bool disabled);

  /// @notice Thrown when `onReport` runs but no GSM in the report had fees to distribute.
  error NothingToDistribute();

  /// @notice Thrown when `setDisabled` is passed the current state.
  error StateUnchanged();

  /// @notice Whether the robot is excluded from automation.
  function isDisabled() external view returns (bool);

  /// @notice Exclude or include the robot from automation. Owner or guardian.
  /// @param disabled Whether to exclude the robot from automation.
  function setDisabled(bool disabled) external;
}
