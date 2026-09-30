// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IStataTokenV2} from 'aave-v3-origin/contracts/extensions/stata-token/interfaces/IStataTokenV2.sol';
import {IRewardsDistributor} from 'aave-v3-origin/contracts/rewards/interfaces/IRewardsDistributor.sol';

import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

/// @notice `IStataTokenV2` plus the public `INCENTIVES_CONTROLLER` getter, which
/// `refreshRewardTokens()` reads rewards from but no upstream interface exposes.
interface IStataToken is IStataTokenV2 {
  function INCENTIVES_CONTROLLER() external view returns (IRewardsDistributor);
}

/// @title IRefreshRewardsReceiver
/// @notice Robot that registers reward tokens added to an aToken after its
/// stataToken was created, by calling `refreshRewardTokens()` on the stataToken.
/// @dev `checkData` is `abi.encode(address factory)`; `performData` and the
/// `report` are `abi.encode(address factory, address[] stataTokens)`.
interface IRefreshRewardsReceiver is IAaveCREReceiver {
  /// @notice Emitted for each stataToken whose reward tokens were refreshed.
  /// @param stataToken The stataToken that was refreshed.
  event RefreshSucceeded(address indexed stataToken);

  /// @notice Emitted when a factory is added to or removed from the automation allowlist.
  /// @param factory The stataToken factory updated.
  /// @param enabled Whether the factory is now enabled for automation.
  event FactoryStatusUpdated(address indexed factory, bool enabled);

  /// @notice Thrown when `onReport` runs for a factory that isn't enabled, or nothing in the
  /// batch needed a refresh.
  error ConditionsNotMet();

  /// @notice Thrown when trying to enable the zero address as a factory.
  error InvalidFactory();

  /// @notice Thrown when enabling / disabling a factory that already has that status.
  /// @param factory The factory updated.
  /// @param enabled The status that was requested.
  error FactoryStatusUnchanged(address factory, bool enabled);

  /// @notice Max stataTokens returned by a single `checkUpkeep` (the rest are picked up next tick).
  function MAX_ACTIONS() external pure returns (uint256);

  /// @notice Add a stataToken factory to the automation allowlist. Owner-only.
  /// @param factory The factory to enable. Must be non-zero and not already enabled.
  function enableFactory(address factory) external;

  /// @notice Remove a stataToken factory from the automation allowlist. Owner or guardian.
  /// @param factory The factory to disable. Must be currently enabled.
  function disableFactory(address factory) external;

  /// @notice Whether a stataToken factory is enabled for automation.
  /// @param factory The factory to query.
  function isFactoryEnabled(address factory) external view returns (bool);
}
