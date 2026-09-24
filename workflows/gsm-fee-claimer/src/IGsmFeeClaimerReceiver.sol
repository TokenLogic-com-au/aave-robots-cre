// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

/// @notice Minimal view of a GHO GSM (Gho Stability Module) fee surface.
interface IGsmFees {
  /// @notice Fees accrued by the GSM and not yet sent to the GHO treasury.
  function getAccruedFees() external view returns (uint256);

  /// @notice Sends the accrued fees to the GHO treasury. Permissionless, no-op without fees.
  function distributeFeesToTreasury() external;
}

/// @title IGsmFeeClaimerReceiver
/// @notice Robot that pushes accrued GSM fees to the GHO treasury.
/// @dev `checkData` is `abi.encode(address[] gsms, uint256 minFees)`. `checkUpkeep`
/// returns the GSMs holding at least `minFees` as `abi.encode(address[])`, which the
/// workflow signs and passes as `report`.
interface IGsmFeeClaimerReceiver is IAaveCREReceiver {
  /// @notice Emitted when the robot is excluded from / included in automation.
  /// @param disabled Whether the robot is now excluded from automation.
  event AutomationDisabled(bool disabled);

  /// @notice Thrown when `onReport` runs while the robot is excluded from automation.
  error Disabled();

  /// @notice Thrown when `setDisabled` is passed the current state.
  error StateUnchanged();

  /// @notice Whether the robot is excluded from automation.
  function isDisabled() external view returns (bool);

  /// @notice Exclude or include the robot from automation. Owner or guardian.
  /// @param disabled Whether to exclude the robot from automation.
  function setDisabled(bool disabled) external;
}
