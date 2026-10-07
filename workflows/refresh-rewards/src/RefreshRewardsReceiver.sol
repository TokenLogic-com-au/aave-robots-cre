// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableWithGuardian} from 'solidity-utils/contracts/access-control/OwnableWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';
import {Rescuable} from 'aave-v4/utils/Rescuable.sol';
import {IStataTokenFactory} from 'aave-v3-origin/contracts/extensions/stata-token/interfaces/IStataTokenFactory.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';
import {IRefreshRewardsReceiver, IStataToken} from './IRefreshRewardsReceiver.sol';

/// @title RefreshRewardsReceiver
/// @author Aave Labs
/// @notice Receives reports from the CRE workflow and registers reward tokens
/// that were added to an aToken after its stataToken was created.
/// @dev Needs no on-chain role: `refreshRewardTokens()` is permissionless.
contract RefreshRewardsReceiver is IRefreshRewardsReceiver, OwnableWithGuardian, Rescuable {
  /// @inheritdoc IRefreshRewardsReceiver
  uint256 public constant override MAX_ACTIONS = 10;

  mapping(address factory => bool) internal _enabled;

  /// @param initialOwner_ The address of the initial owner.
  /// @param initialGuardian_ The address of the initial guardian.
  /// @param initialFactories_ The stataToken factories enabled for automation at deployment.
  constructor(
    address initialOwner_,
    address initialGuardian_,
    address[] memory initialFactories_
  ) OwnableWithGuardian(initialOwner_, initialGuardian_) {
    for (uint256 i = 0; i < initialFactories_.length; i++) {
      _enableFactory(initialFactories_[i]);
    }
  }

  /// @inheritdoc IRefreshRewardsReceiver
  function enableFactory(address factory) external onlyOwner {
    _enableFactory(factory);
  }

  /// @inheritdoc IRefreshRewardsReceiver
  function disableFactory(address factory) external onlyOwnerOrGuardian {
    require(_enabled[factory], FactoryStatusUnchanged(factory, false));
    _enabled[factory] = false;
    emit FactoryStatusUpdated(factory, false);
  }

  /// @inheritdoc IAaveCREReceiver
  function checkUpkeep(
    bytes calldata checkData
  ) external view returns (bool upkeepNeeded, bytes memory performData) {
    address factory = abi.decode(checkData, (address));
    if (!_enabled[factory]) return (false, '');

    address[] memory stataTokens = IStataTokenFactory(factory).getStataTokens();
    uint256 maxCount = stataTokens.length < MAX_ACTIONS ? stataTokens.length : MAX_ACTIONS;
    address[] memory buffer = new address[](maxCount);
    uint256 count = 0;

    for (uint256 i = 0; i < stataTokens.length && count < maxCount; i++) {
      if (_needsRefresh(stataTokens[i])) {
        buffer[count++] = stataTokens[i];
      }
    }
    if (count == 0) return (false, '');

    address[] memory toRefresh = new address[](count);
    for (uint256 i = 0; i < count; i++) toRefresh[i] = buffer[i];
    return (true, abi.encode(factory, toRefresh));
  }

  /// @inheritdoc IReceiver
  /// @dev Reverts `ConditionsNotMet` if `factory` isn't enabled. Skips stataTokens not deployed
  /// by `factory` or no longer needing a refresh, and reverts `ConditionsNotMet` if none is
  /// left, so a stale report fails `estimateGas`.
  function onReport(bytes calldata /* metadata */, bytes calldata report) external override {
    (address factory, address[] memory stataTokens) = abi.decode(report, (address, address[]));
    require(_enabled[factory], ConditionsNotMet());

    uint256 refreshed = 0;
    for (uint256 i = 0; i < stataTokens.length; i++) {
      if (!_isFactoryStataToken(factory, stataTokens[i])) continue;
      if (!_needsRefresh(stataTokens[i])) continue;
      IStataToken(stataTokens[i]).refreshRewardTokens();
      emit RefreshSucceeded(stataTokens[i]);
      refreshed++;
    }
    require(refreshed > 0, ConditionsNotMet());
  }

  /// @inheritdoc IRefreshRewardsReceiver
  function isFactoryEnabled(address factory) external view returns (bool) {
    return _enabled[factory];
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return
      interfaceId == type(IReceiver).interfaceId ||
      interfaceId == type(IAaveCREReceiver).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }

  function _enableFactory(address factory) internal {
    require(factory != address(0), InvalidFactory());
    require(!_enabled[factory], FactoryStatusUnchanged(factory, true));
    _enabled[factory] = true;
    emit FactoryStatusUpdated(factory, true);
  }

  /// @dev Whether `stataToken` is the factory's stataToken for its underlying asset.
  function _isFactoryStataToken(address factory, address stataToken) internal view returns (bool) {
    return IStataTokenFactory(factory).getStataToken(IStataToken(stataToken).asset()) == stataToken;
  }

  /// @dev Whether the stataToken's incentives controller lists a reward for its
  /// aToken that the stataToken has not registered yet. Reads the same controller
  /// `refreshRewardTokens()` does.
  function _needsRefresh(address stataToken) internal view returns (bool) {
    IStataToken stata = IStataToken(stataToken);
    address[] memory rewards = stata.INCENTIVES_CONTROLLER().getRewardsByAsset(stata.aToken());
    for (uint256 i = 0; i < rewards.length; i++) {
      if (!stata.isRegisteredRewardToken(rewards[i])) return true;
    }
    return false;
  }

  /// @inheritdoc Rescuable
  function _rescueGuardian() internal view override returns (address) {
    return owner();
  }
}
