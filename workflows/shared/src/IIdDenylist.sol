// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IIdDenylist
/// @author Aave Labs
/// @notice Exclusion of single numbered items (proposals, payloads) from a robot's automation.
/// Every new item is automated without configuration.
interface IIdDenylist {
  /// @notice Emitted when an item is excluded from or included back into automation.
  /// @param id The item id.
  /// @param disabled Whether the item is now excluded from automation.
  event AutomationDisabled(uint256 indexed id, bool disabled);

  /// @notice Thrown when enabling / disabling an item that already has that status.
  /// @param id The item id.
  error AutomationStatusUnchanged(uint256 id);

  /// @notice Include a previously disabled item back into automation. Owner only.
  /// @param id The item id. Must be currently disabled.
  function enableAutomation(uint256 id) external;

  /// @notice Exclude an item from automation. Owner or guardian.
  /// @param id The item id. Must not be disabled already.
  function disableAutomation(uint256 id) external;

  /// @notice Whether an item is excluded from automation.
  /// @param id The item id.
  function isDisabled(uint256 id) external view returns (bool);
}
