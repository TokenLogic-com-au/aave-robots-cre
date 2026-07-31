// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {AaveV3Ethereum} from 'aave-address-book/AaveV3Ethereum.sol';

import {RefreshRewardsReceiver} from '../src/RefreshRewardsReceiver.sol';
import {IRefreshRewardsReceiver, IStataTokenFactory, IStataTokenV2, IRewardsController} from '../src/IRefreshRewardsReceiver.sol';

contract RefreshRewardsReceiverForkTest is Test {
  RefreshRewardsReceiver internal robot;
  address internal owner = makeAddr('fork-owner');
  address internal guardian = makeAddr('fork-guardian');
  address internal anyone = makeAddr('fork-anyone');

  IStataTokenFactory internal factory = IStataTokenFactory(AaveV3Ethereum.STATA_FACTORY);
  IRewardsController internal controller =
    IRewardsController(AaveV3Ethereum.DEFAULT_INCENTIVES_CONTROLLER);

  function setUp() public {
    vm.createSelectFork(vm.envString('RPC_MAINNET'));
    robot = new RefreshRewardsReceiver(owner, guardian);
  }

  function test_fork_factory_hasStataTokens() public view {
    assertGt(factory.getStataTokens().length, 0);
  }

  /// The minimal local interfaces must match the real deployed ABIs — exercise
  /// the full read path checkUpkeep relies on, against real contracts.
  function test_fork_readPath_interfacesMatch() public view {
    address[] memory stataTokens = factory.getStataTokens();
    address stata = stataTokens[0];
    address aToken = IStataTokenV2(stata).aToken();
    assertTrue(aToken != address(0));

    address[] memory rewards = controller.getRewardsByAsset(aToken);
    for (uint256 i = 0; i < rewards.length; i++) {
      // must not revert — returns a bool
      IStataTokenV2(stata).isRegisteredRewardToken(rewards[i]);
    }
  }

  function test_fork_checkUpkeep_doesNotRevert() public view {
    // Enumerates every real stataToken; just assert it returns without reverting.
    robot.checkUpkeep(abi.encode(factory, controller));
  }

  function test_fork_onReport_revertsConditionsNotMet_whenFullyRegistered() public {
    (bool found, address stata) = _findFullyRegisteredToken();
    if (!found) {
      vm.skip(true);
    }
    address[] memory batch = new address[](1);
    batch[0] = stata;

    vm.prank(anyone);
    vm.expectRevert(IRefreshRewardsReceiver.ConditionsNotMet.selector);
    robot.onReport('', abi.encode(controller, batch));
  }

  function test_fork_onReport_refreshes_whenRewardUnregistered() public {
    (bool found, address stata, address reward) = _findTokenNeedingRefresh();
    if (!found) {
      vm.skip(true);
    }
    assertFalse(IStataTokenV2(stata).isRegisteredRewardToken(reward));

    address[] memory batch = new address[](1);
    batch[0] = stata;

    vm.expectEmit(address(robot));
    emit IRefreshRewardsReceiver.RefreshSucceeded(stata);

    vm.prank(anyone);
    robot.onReport('', abi.encode(controller, batch));

    assertTrue(IStataTokenV2(stata).isRegisteredRewardToken(reward));
  }

  function _findFullyRegisteredToken() internal view returns (bool, address) {
    address[] memory stataTokens = factory.getStataTokens();
    for (uint256 i = 0; i < stataTokens.length; i++) {
      if (!_needsRefresh(stataTokens[i])) return (true, stataTokens[i]);
    }
    return (false, address(0));
  }

  function _findTokenNeedingRefresh() internal view returns (bool, address, address) {
    address[] memory stataTokens = factory.getStataTokens();
    for (uint256 i = 0; i < stataTokens.length; i++) {
      address aToken = IStataTokenV2(stataTokens[i]).aToken();
      address[] memory rewards = controller.getRewardsByAsset(aToken);
      for (uint256 j = 0; j < rewards.length; j++) {
        if (!IStataTokenV2(stataTokens[i]).isRegisteredRewardToken(rewards[j])) {
          return (true, stataTokens[i], rewards[j]);
        }
      }
    }
    return (false, address(0), address(0));
  }

  function _needsRefresh(address stata) internal view returns (bool) {
    address aToken = IStataTokenV2(stata).aToken();
    address[] memory rewards = controller.getRewardsByAsset(aToken);
    for (uint256 j = 0; j < rewards.length; j++) {
      if (!IStataTokenV2(stata).isRegisteredRewardToken(rewards[j])) return true;
    }
    return false;
  }
}
