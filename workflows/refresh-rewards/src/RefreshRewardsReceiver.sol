// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableWithGuardian} from 'solidity-utils/contracts/access-control/OwnableWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';
import {IRefreshRewardsReceiver, IStataTokenFactory, IStataTokenV2, IRewardsController} from './IRefreshRewardsReceiver.sol';

/// @title RefreshRewardsReceiver
/// @author Aave Labs
/// @notice Receives reports from the CRE workflow and registers reward tokens
/// that were added to an aToken after its stataToken was created. Native CRE
/// re-implementation of BGD Labs' `RefreshRewardsRobot`.
/// @dev `refreshRewardTokens()` is permissionless on the stataToken, so this
/// contract needs no on-chain role. It only reads state and forwards the call.
contract RefreshRewardsReceiver is IRefreshRewardsReceiver, OwnableWithGuardian {
  /// @inheritdoc IRefreshRewardsReceiver
  uint256 public constant override MAX_ACTIONS = 10;

  mapping(address stataToken => bool) internal _disabled;

  /// @param initialOwner_ The address of the initial owner.
  /// @param initialGuardian_ The address of the initial guardian.
  constructor(
    address initialOwner_,
    address initialGuardian_
  ) OwnableWithGuardian(initialOwner_, initialGuardian_) {}

  /// @inheritdoc IAaveCREReceiver
  function checkUpkeep(
    bytes calldata checkData
  ) external view returns (bool upkeepNeeded, bytes memory performData) {
    (IStataTokenFactory factory, IRewardsController controller) = abi.decode(
      checkData,
      (IStataTokenFactory, IRewardsController)
    );

    address[] memory stataTokens = factory.getStataTokens();
    address[] memory buffer = new address[](stataTokens.length);
    uint256 count = 0;

    for (uint256 i = 0; i < stataTokens.length && count < MAX_ACTIONS; i++) {
      if (_needsRefresh(controller, stataTokens[i])) {
        buffer[count++] = stataTokens[i];
      }
    }
    if (count == 0) return (false, '');

    address[] memory toRefresh = new address[](count);
    for (uint256 i = 0; i < count; i++) toRefresh[i] = buffer[i];
    return (true, abi.encode(controller, toRefresh));
  }

  /// @inheritdoc IReceiver
  /// @dev Re-validates each stataToken so a stale report can't force redundant refreshes.
  function onReport(bytes calldata /* metadata */, bytes calldata report) external override {
    (IRewardsController controller, address[] memory stataTokens) = abi.decode(
      report,
      (IRewardsController, address[])
    );

    uint256 refreshed = 0;
    for (uint256 i = 0; i < stataTokens.length; i++) {
      if (!_needsRefresh(controller, stataTokens[i])) continue;
      IStataTokenV2(stataTokens[i]).refreshRewardTokens();
      emit RefreshSucceeded(stataTokens[i]);
      refreshed++;
    }
    require(refreshed > 0, ConditionsNotMet());
  }

  /// @inheritdoc IRefreshRewardsReceiver
  function isDisabled(address stataToken) public view returns (bool) {
    return _disabled[stataToken];
  }

  /// @inheritdoc IRefreshRewardsReceiver
  function setAutomationDisabled(address stataToken, bool disabled) external onlyOwnerOrGuardian {
    _disabled[stataToken] = disabled;
    emit AutomationDisabledSet(stataToken, disabled);
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return
      interfaceId == type(IReceiver).interfaceId ||
      interfaceId == type(IAaveCREReceiver).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }

  /// @dev A stataToken needs a refresh when it is enabled for automation and the
  /// rewards controller lists a reward for its aToken that the stataToken has not
  /// yet registered.
  function _needsRefresh(
    IRewardsController controller,
    address stataToken
  ) internal view returns (bool) {
    if (_disabled[stataToken]) return false;
    address aToken = IStataTokenV2(stataToken).aToken();
    address[] memory rewards = controller.getRewardsByAsset(aToken);
    for (uint256 i = 0; i < rewards.length; i++) {
      if (!IStataTokenV2(stataToken).isRegisteredRewardToken(rewards[i])) return true;
    }
    return false;
  }
}
