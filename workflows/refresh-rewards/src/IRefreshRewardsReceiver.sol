// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

/// @notice Minimal view of the Aave v3 stataToken factory.
interface IStataTokenFactory {
  /// @notice All stataTokens deployed by this factory.
  function getStataTokens() external view returns (address[] memory);
}

/// @notice Minimal view of an Aave v3 stataToken (static aToken).
interface IStataTokenV2 {
  /// @notice The underlying aToken this stataToken wraps.
  function aToken() external view returns (address);

  /// @notice Whether `reward` is already registered on this stataToken.
  function isRegisteredRewardToken(address reward) external view returns (bool);

  /// @notice Registers any reward tokens of the underlying aToken not yet tracked. Permissionless.
  function refreshRewardTokens() external;
}

/// @notice Minimal view of the Aave v3 rewards controller.
interface IRewardsController {
  /// @notice Reward tokens configured for `asset` (the aToken).
  function getRewardsByAsset(address asset) external view returns (address[] memory);
}

/// @title IRefreshRewardsReceiver
/// @notice Robot that registers reward tokens added to an aToken *after* its
/// stataToken was created — stataTokens do not auto-register rewards configured
/// later. It enumerates a factory's stataTokens, finds any with an unregistered
/// reward, and calls `refreshRewardTokens()` on them.
/// @dev `checkData` is `abi.encode(IStataTokenFactory factory, IRewardsController controller)`;
/// the `report` is `abi.encode(IRewardsController controller, address[] stataTokens)`.
interface IRefreshRewardsReceiver is IAaveCREReceiver {
  /// @notice Emitted for each stataToken whose reward tokens were refreshed.
  /// @param stataToken The stataToken that was refreshed.
  event RefreshSucceeded(address indexed stataToken);

  /// @notice Emitted when a stataToken is excluded from / included in automation.
  /// @param stataToken The stataToken toggled.
  /// @param disabled Whether the stataToken is now excluded from automation.
  event AutomationDisabledSet(address indexed stataToken, bool disabled);

  /// @notice Thrown when `onReport` runs but no stataToken in the batch needed a refresh.
  error ConditionsNotMet();

  /// @notice Max stataTokens returned by a single `checkUpkeep` (the rest are picked up next tick).
  function MAX_ACTIONS() external pure returns (uint256);

  /// @notice Whether a stataToken is excluded from automation.
  /// @param stataToken The stataToken to query.
  function isDisabled(address stataToken) external view returns (bool);

  /// @notice Exclude or include a stataToken from automation. Owner or guardian.
  /// @param stataToken The stataToken to toggle.
  /// @param disabled Whether to exclude the stataToken from automation.
  function setAutomationDisabled(address stataToken, bool disabled) external;
}
