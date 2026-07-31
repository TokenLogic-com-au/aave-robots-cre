// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

/// @notice Minimal view of an Aave Proof of Reserve executor.
interface IProofOfReserveExecutor {
  /// @notice Whether every reserve tracked by the executor is currently backed.
  function areAllReservesBacked() external view returns (bool);

  /// @notice Whether the emergency action would change any state right now.
  function isEmergencyActionPossible() external view returns (bool);

  /// @notice Freezes reserves that fail proof-of-reserve validation. Permissionless.
  function executeEmergencyAction() external;
}

/// @title IProofOfReserveReceiver
/// @notice Robot that runs an Aave Proof of Reserve executor's emergency action
/// when a reserve becomes unbacked. Native CRE re-implementation of BGD Labs'
/// `ProofOfReserveKeeper`.
/// @dev `checkData` and the `report` are both `abi.encode(address executor)`.
interface IProofOfReserveReceiver is IAaveCREReceiver {
  /// @notice Emitted when the emergency action is executed on an executor.
  /// @param executor The executor the emergency action ran on.
  event EmergencyActionExecuted(address indexed executor);

  /// @notice Emitted when an executor is excluded from / included in automation.
  /// @param executor The executor toggled.
  /// @param disabled Whether the executor is now excluded from automation.
  event ExecutorDisabled(address indexed executor, bool disabled);

  /// @notice Thrown when `onReport` runs but the executor's emergency action is not possible.
  error EmergencyActionNotPossible();

  /// @notice Whether an executor is excluded from automation.
  /// @param executor The executor to query.
  function isDisabled(address executor) external view returns (bool);

  /// @notice Exclude or include an executor from automation. Owner or guardian.
  /// @param executor The executor to toggle.
  /// @param disabled Whether to exclude the executor from automation.
  function setDisabled(address executor, bool disabled) external;
}
