// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IUmbrella} from 'aave-address-book/common/IUmbrella.sol';

import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

/// @notice `UmbrellaStakeToken` getters read by the robot.
interface IUmbrellaStakeToken {
  function getMaxSlashableAssets() external view returns (uint256);

  function paused() external view returns (bool);
}

/// @title ISlashingReceiver
/// @notice Robot that triggers Umbrella slashing on reserves that have a slashable deficit.
/// @dev `checkData` is unused (the Umbrella is an immutable of the contract); `performData`
/// and the `report` are `abi.encode(address[] reserves)`.
interface ISlashingReceiver is IAaveCREReceiver {
  /// @notice Emitted for each reserve slashed by `onReport`.
  /// @param reserve The reserve that was slashed.
  /// @param amount Amount of the deficit covered.
  event ReserveSlashed(address indexed reserve, uint256 amount);

  /// @notice Emitted when a reserve is excluded from or included back into automation.
  /// @param reserve The reserve updated.
  /// @param disabled Whether the reserve is now excluded from automation.
  event ReserveDisabled(address indexed reserve, bool disabled);

  /// @notice Thrown when `onReport` runs but no reserve in the batch was slashed.
  error NoSlashesPerformed();

  /// @notice Thrown when the Umbrella passed to the constructor is the zero address.
  error InvalidUmbrella();

  /// @notice Thrown when disabling / enabling a reserve that already has that status.
  /// @param reserve The reserve updated.
  /// @param disabled The status that was requested.
  error ReserveStatusUnchanged(address reserve, bool disabled);

  /// @notice The Umbrella coordinator this robot slashes through.
  function UMBRELLA() external view returns (IUmbrella);

  /// @notice Max reserves returned by a single `checkUpkeep`.
  function MAX_CHECK_SIZE() external pure returns (uint256);

  /// @notice Exclude a reserve from automation. Owner or guardian.
  /// @param reserve The reserve to disable. Must not be disabled already.
  function disableReserve(address reserve) external;

  /// @notice Include a previously disabled reserve back into automation. Owner-only.
  /// @param reserve The reserve to enable. Must be currently disabled.
  function enableReserve(address reserve) external;

  /// @notice Whether a reserve is excluded from automation.
  /// @param reserve The reserve to query.
  function isDisabled(address reserve) external view returns (bool);
}
