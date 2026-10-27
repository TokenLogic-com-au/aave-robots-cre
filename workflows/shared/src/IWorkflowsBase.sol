// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAaveCREReceiver} from './IAaveCREReceiver.sol';

/// @title IWorkflowsBase
/// @author Aave Labs
/// @notice Surface shared by every Aave CRE robot on top of `IAaveCREReceiver`: a global
/// automation switch. While automation is disabled `checkUpkeep` reports no upkeep and
/// `onReport` reverts.
interface IWorkflowsBase is IAaveCREReceiver {
  /// @notice Emitted when the robot is excluded from or included back into automation.
  /// @param disabled Whether the robot is now excluded from automation.
  event AutomationDisabled(bool disabled);

  /// @notice Thrown when `onReport` is called while automation is disabled.
  error AutomationIsDisabled();

  /// @notice Thrown when enabling / disabling automation that already has that status.
  error StateUnchanged();

  /// @notice Include the robot back into automation. Owner only.
  function enableAutomation() external;

  /// @notice Exclude the robot from automation. Owner or guardian.
  function disableAutomation() external;

  /// @notice Whether the robot is excluded from automation.
  function isDisabled() external view returns (bool);
}
