// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

/// @notice Minimal view of an Aave Umbrella stake token (`UmbrellaStakeToken`).
interface IUmbrellaStakeToken {
  /// @notice Assets that could currently be slashed from this stake token.
  function getMaxSlashableAssets() external view returns (uint256);

  /// @notice Whether the stake token is paused (slashing is blocked while paused).
  function paused() external view returns (bool);
}

/// @notice Minimal view of the Aave Umbrella coordinator.
interface IUmbrella {
  /// @notice Data configured for a stake token. Only `reserve` is used here.
  struct StakeTokenData {
    address underlyingOracle;
    address reserve;
  }

  /// @notice All stake tokens registered on Umbrella.
  function getStkTokens() external view returns (address[] memory);

  /// @notice Config for a stake token (carries the reserve it covers).
  function getStakeTokenData(address stakeToken) external view returns (StakeTokenData memory);

  /// @notice Whether `reserve` has a deficit that can be slashed, and by how much.
  function isReserveSlashable(address reserve) external view returns (bool flag, uint256 amount);

  /// @notice Slash `reserve` to cover its deficit. Permissionless (gated by the deficit check).
  function slash(address reserve) external returns (uint256);
}

/// @title ISlashingReceiver
/// @notice Robot that triggers Umbrella slashing on reserves that have a
/// slashable deficit. Native CRE re-implementation of BGD Labs' `SlashingRobot`.
/// @dev `checkData` is unused (the Umbrella is an immutable of the contract); the
/// `report` is `abi.encode(address[] reserves)`.
interface ISlashingReceiver is IAaveCREReceiver {
  /// @notice Emitted for each reserve slashed by `onReport`.
  /// @param reserve The reserve that was slashed.
  /// @param amount Amount of the deficit covered.
  event ReserveSlashed(address indexed reserve, uint256 amount);

  /// @notice Emitted when a reserve is excluded from / included in automation.
  /// @param reserve The reserve toggled.
  /// @param disabled Whether the reserve is now excluded from automation.
  event ReserveDisabled(address indexed reserve, bool disabled);

  /// @notice Thrown when `onReport` runs but no reserve in the batch was slashed.
  error NoSlashesPerformed();

  /// @notice The Umbrella coordinator this robot slashes through.
  function UMBRELLA() external view returns (IUmbrella);

  /// @notice Max reserves returned by a single `checkUpkeep` (the rest are picked up next tick).
  function MAX_CHECK_SIZE() external pure returns (uint256);

  /// @notice Whether a reserve is excluded from automation.
  /// @param reserve The reserve to query.
  function isDisabled(address reserve) external view returns (bool);

  /// @notice Exclude or include a reserve from automation. Owner or guardian.
  /// @param reserve The reserve to toggle.
  /// @param disabled Whether to exclude the reserve from automation.
  function setDisabled(address reserve, bool disabled) external;
}
