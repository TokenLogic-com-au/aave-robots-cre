// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {Ownable} from 'openzeppelin-contracts/contracts/access/Ownable.sol';
import {IWithGuardian} from 'solidity-utils/contracts/access-control/interfaces/IWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

import {RefreshRewardsReceiver} from '../src/RefreshRewardsReceiver.sol';
import {IRefreshRewardsReceiver, IStataTokenFactory, IStataTokenV2, IRewardsController} from '../src/IRefreshRewardsReceiver.sol';

contract RefreshRewardsReceiverTest is Test {
  RefreshRewardsReceiver internal robot;

  address internal owner;
  address internal guardian;
  address internal bob;
  address internal anyone;

  address internal factory;
  address internal controller;
  address internal stataA;
  address internal stataB;
  address internal aTokenA;
  address internal aTokenB;
  address internal reward;

  function setUp() public {
    owner = makeAddr('owner');
    guardian = makeAddr('guardian');
    bob = makeAddr('bob');
    anyone = makeAddr('anyone');

    factory = makeAddr('factory');
    controller = makeAddr('controller');
    stataA = makeAddr('stataA');
    stataB = makeAddr('stataB');
    aTokenA = makeAddr('aTokenA');
    aTokenB = makeAddr('aTokenB');
    reward = makeAddr('reward');

    _mockAToken(stataA, aTokenA);
    _mockAToken(stataB, aTokenB);

    robot = new RefreshRewardsReceiver(owner, guardian);
  }

  // --- metadata -----------------------------------------------------------

  function test_constructor_setsOwnerAndGuardian() public view {
    assertEq(robot.owner(), owner);
    assertEq(robot.guardian(), guardian);
  }

  function test_MAX_ACTIONS_isTen() public view {
    assertEq(robot.MAX_ACTIONS(), 10);
  }

  function test_supportsInterface() public view {
    assertTrue(robot.supportsInterface(type(IReceiver).interfaceId));
    assertTrue(robot.supportsInterface(type(IAaveCREReceiver).interfaceId));
    assertTrue(robot.supportsInterface(type(IERC165).interfaceId));
    assertFalse(robot.supportsInterface(0xffffffff));
  }

  // --- checkUpkeep --------------------------------------------------------

  function test_checkUpkeep_returnsFalse_whenNoStataTokens() public {
    _mockStataTokens(new address[](0));
    (bool needed, bytes memory performData) = robot.checkUpkeep(_checkData());
    assertFalse(needed);
    assertEq(performData, '');
  }

  function test_checkUpkeep_returnsFalse_whenAllRewardsRegistered() public {
    _mockStataTokens(_two(stataA, stataB));
    _mockRewards(aTokenA, _one(reward));
    _mockRewards(aTokenB, _one(reward));
    _mockRegistered(stataA, reward, true);
    _mockRegistered(stataB, reward, true);

    (bool needed, bytes memory performData) = robot.checkUpkeep(_checkData());
    assertFalse(needed);
    assertEq(performData, '');
  }

  function test_checkUpkeep_returnsFalse_whenNoRewardsConfigured() public {
    _mockStataTokens(_one(stataA));
    _mockRewards(aTokenA, new address[](0));

    (bool needed, ) = robot.checkUpkeep(_checkData());
    assertFalse(needed);
  }

  function test_checkUpkeep_returnsToken_whenRewardUnregistered() public {
    _mockStataTokens(_two(stataA, stataB));
    _mockRewards(aTokenA, _one(reward));
    _mockRewards(aTokenB, _one(reward));
    _mockRegistered(stataA, reward, false); // needs refresh
    _mockRegistered(stataB, reward, true);

    (bool needed, bytes memory performData) = robot.checkUpkeep(_checkData());
    assertTrue(needed);

    (address ctrl, address[] memory tokens) = abi.decode(performData, (address, address[]));
    assertEq(ctrl, controller);
    assertEq(tokens.length, 1);
    assertEq(tokens[0], stataA);
  }

  function test_checkUpkeep_skipsDisabledTokens() public {
    _mockStataTokens(_one(stataA));
    _mockRewards(aTokenA, _one(reward));
    _mockRegistered(stataA, reward, false);

    vm.prank(owner);
    robot.setAutomationDisabled(stataA, true);

    (bool needed, ) = robot.checkUpkeep(_checkData());
    assertFalse(needed);
  }

  function test_checkUpkeep_capsAtMaxActions() public {
    uint256 total = robot.MAX_ACTIONS() + 3;
    address[] memory tokens = new address[](total);
    for (uint256 i = 0; i < total; i++) {
      address stata = makeAddr(string(abi.encodePacked('stata', vm.toString(i))));
      address aToken = makeAddr(string(abi.encodePacked('aToken', vm.toString(i))));
      tokens[i] = stata;
      _mockAToken(stata, aToken);
      _mockRewards(aToken, _one(reward));
      _mockRegistered(stata, reward, false);
    }
    _mockStataTokens(tokens);

    (bool needed, bytes memory performData) = robot.checkUpkeep(_checkData());
    assertTrue(needed);
    (, address[] memory picked) = abi.decode(performData, (address, address[]));
    assertEq(picked.length, robot.MAX_ACTIONS());
  }

  // --- onReport -----------------------------------------------------------

  function test_onReport_refreshes_whenAnyoneCalls() public {
    _mockStataTokens(_one(stataA));
    _mockRewards(aTokenA, _one(reward));
    _mockRegistered(stataA, reward, false);
    _mockRefresh(stataA);

    vm.expectCall(stataA, abi.encodeWithSelector(IStataTokenV2.refreshRewardTokens.selector));
    vm.expectEmit(address(robot));
    emit IRefreshRewardsReceiver.RefreshSucceeded(stataA);

    vm.prank(anyone);
    robot.onReport('', abi.encode(controller, _one(stataA)));
  }

  function test_onReport_revertsWith_ConditionsNotMet_whenNothingToRefresh() public {
    _mockRewards(aTokenA, _one(reward));
    _mockRegistered(stataA, reward, true); // already registered

    vm.prank(anyone);
    vm.expectRevert(IRefreshRewardsReceiver.ConditionsNotMet.selector);
    robot.onReport('', abi.encode(controller, _one(stataA)));
  }

  function test_onReport_skipsStaleToken_andRefreshesRest() public {
    _mockRewards(aTokenA, _one(reward));
    _mockRewards(aTokenB, _one(reward));
    _mockRegistered(stataA, reward, true); // stale: already registered → skip
    _mockRegistered(stataB, reward, false); // still needs refresh
    _mockRefresh(stataB);

    vm.expectCall(stataB, abi.encodeWithSelector(IStataTokenV2.refreshRewardTokens.selector));

    vm.prank(anyone);
    robot.onReport('', abi.encode(controller, _two(stataA, stataB)));
  }

  // --- admin --------------------------------------------------------------

  function test_setAutomationDisabled_byOwner() public {
    vm.expectEmit(address(robot));
    emit IRefreshRewardsReceiver.AutomationDisabledSet(stataA, true);

    vm.prank(owner);
    robot.setAutomationDisabled(stataA, true);
    assertTrue(robot.isDisabled(stataA));
  }

  function test_setAutomationDisabled_byGuardian() public {
    vm.prank(guardian);
    robot.setAutomationDisabled(stataA, true);
    assertTrue(robot.isDisabled(stataA));
  }

  function test_setAutomationDisabled_revertsWith_NotOwnerOrGuardian() public {
    vm.prank(bob);
    vm.expectRevert(
      abi.encodeWithSelector(IWithGuardian.OnlyGuardianOrOwnerInvalidCaller.selector, bob)
    );
    robot.setAutomationDisabled(stataA, true);
  }

  // --- mock helpers -------------------------------------------------------

  function _checkData() internal view returns (bytes memory) {
    return abi.encode(factory, controller);
  }

  function _mockStataTokens(address[] memory tokens) internal {
    vm.mockCall(
      factory,
      abi.encodeWithSelector(IStataTokenFactory.getStataTokens.selector),
      abi.encode(tokens)
    );
  }

  function _mockAToken(address stata, address aToken) internal {
    vm.mockCall(stata, abi.encodeWithSelector(IStataTokenV2.aToken.selector), abi.encode(aToken));
  }

  function _mockRewards(address aToken, address[] memory rewards) internal {
    vm.mockCall(
      controller,
      abi.encodeWithSelector(IRewardsController.getRewardsByAsset.selector, aToken),
      abi.encode(rewards)
    );
  }

  function _mockRegistered(address stata, address reward_, bool isRegistered) internal {
    vm.mockCall(
      stata,
      abi.encodeWithSelector(IStataTokenV2.isRegisteredRewardToken.selector, reward_),
      abi.encode(isRegistered)
    );
  }

  function _mockRefresh(address stata) internal {
    vm.mockCall(stata, abi.encodeWithSelector(IStataTokenV2.refreshRewardTokens.selector), '');
  }

  function _one(address a) internal pure returns (address[] memory arr) {
    arr = new address[](1);
    arr[0] = a;
  }

  function _two(address a, address b) internal pure returns (address[] memory arr) {
    arr = new address[](2);
    arr[0] = a;
    arr[1] = b;
  }
}
