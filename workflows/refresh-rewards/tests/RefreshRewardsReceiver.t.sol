// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, Vm} from 'forge-std/Test.sol';

import {Ownable} from 'openzeppelin-contracts/contracts/access/Ownable.sol';
import {IWithGuardian} from 'solidity-utils/contracts/access-control/interfaces/IWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';
import {IERC4626} from 'openzeppelin-contracts/contracts/interfaces/IERC4626.sol';
import {IRescuable} from 'aave-v4/interfaces/IRescuable.sol';
import {IStataTokenFactory} from 'aave-v3-origin/contracts/extensions/stata-token/interfaces/IStataTokenFactory.sol';
import {IRewardsDistributor} from 'aave-v3-origin/contracts/rewards/interfaces/IRewardsDistributor.sol';
import {IERC20AaveLM} from 'aave-v3-origin/contracts/extensions/stata-token/interfaces/IERC20AaveLM.sol';
import {IERC4626StataToken} from 'aave-v3-origin/contracts/extensions/stata-token/interfaces/IERC4626StataToken.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

import {RefreshRewardsReceiver} from '../src/RefreshRewardsReceiver.sol';
import {IRefreshRewardsReceiver, IStataToken} from '../src/IRefreshRewardsReceiver.sol';

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
    reward = makeAddr('reward');

    _mockStata(stataA, 'A');
    _mockStata(stataB, 'B');

    robot = new RefreshRewardsReceiver(owner, guardian, _one(factory));
  }

  function test_constructor_setsOwnerAndGuardian() public view {
    assertEq(robot.owner(), owner, 'owner mismatch');
    assertEq(robot.guardian(), guardian, 'guardian mismatch');
  }

  function test_constructor_enablesInitialFactories() public {
    address otherFactory = makeAddr('otherFactory');

    vm.expectEmit();
    emit IRefreshRewardsReceiver.FactoryStatusUpdated(factory, true);
    vm.expectEmit();
    emit IRefreshRewardsReceiver.FactoryStatusUpdated(otherFactory, true);

    RefreshRewardsReceiver deployed = new RefreshRewardsReceiver(
      owner,
      guardian,
      _two(factory, otherFactory)
    );

    assertTrue(deployed.isFactoryEnabled(factory), 'factory not enabled');
    assertTrue(deployed.isFactoryEnabled(otherFactory), 'other factory not enabled');
  }

  function test_constructor_revertsWith_InvalidFactory() public {
    vm.expectRevert(IRefreshRewardsReceiver.InvalidFactory.selector);
    new RefreshRewardsReceiver(owner, guardian, new address[](1));
  }

  function test_constructor_revertsWith_FactoryStatusUnchanged_whenDuplicated() public {
    vm.expectRevert(
      abi.encodeWithSelector(IRefreshRewardsReceiver.FactoryStatusUnchanged.selector, factory, true)
    );
    new RefreshRewardsReceiver(owner, guardian, _two(factory, factory));
  }

  function test_MAX_ACTIONS_isTen() public view {
    assertEq(robot.MAX_ACTIONS(), 10, 'unexpected MAX_ACTIONS');
  }

  function test_supportsInterface() public view {
    assertTrue(robot.supportsInterface(type(IReceiver).interfaceId), 'IReceiver not supported');
    assertTrue(
      robot.supportsInterface(type(IAaveCREReceiver).interfaceId),
      'IAaveCREReceiver not supported'
    );
    assertTrue(robot.supportsInterface(type(IERC165).interfaceId), 'IERC165 not supported');
    assertFalse(robot.supportsInterface(0xffffffff), 'invalid interface id supported');
  }

  function test_checkUpkeep_returnsFalse_whenFactoryNotEnabled() public {
    address otherFactory = makeAddr('otherFactory');
    _mockStataTokens(otherFactory, _one(stataA));
    _mockRewards(stataA, _one(reward));
    _mockRegistered(stataA, reward, false);

    (bool needed, bytes memory performData) = robot.checkUpkeep(abi.encode(otherFactory));
    assertFalse(needed, 'upkeep needed for non-enabled factory');
    assertEq(performData.length, 0, 'performData should be empty');
  }

  function test_checkUpkeep_returnsFalse_whenFactoryDisabled() public {
    _mockStataTokens(factory, _one(stataA));
    _mockRewards(stataA, _one(reward));
    _mockRegistered(stataA, reward, false);

    vm.prank(guardian);
    robot.disableFactory(factory);

    (bool needed, ) = robot.checkUpkeep(abi.encode(factory));
    assertFalse(needed, 'upkeep needed for disabled factory');
  }

  function test_checkUpkeep_returnsFalse_whenNoStataTokens() public {
    _mockStataTokens(factory, new address[](0));

    (bool needed, bytes memory performData) = robot.checkUpkeep(abi.encode(factory));
    assertFalse(needed, 'upkeep needed without stataTokens');
    assertEq(performData.length, 0, 'performData should be empty');
  }

  function test_checkUpkeep_returnsFalse_whenNoRewardsConfigured() public {
    _mockStataTokens(factory, _one(stataA));
    _mockRewards(stataA, new address[](0));

    (bool needed, ) = robot.checkUpkeep(abi.encode(factory));
    assertFalse(needed, 'upkeep needed without rewards');
  }

  function test_fuzz_checkUpkeep(bool registeredA, bool registeredB) public {
    _mockStataTokens(factory, _two(stataA, stataB));
    _mockRewards(stataA, _one(reward));
    _mockRewards(stataB, _one(reward));
    _mockRegistered(stataA, reward, registeredA);
    _mockRegistered(stataB, reward, registeredB);

    (bool needed, bytes memory performData) = robot.checkUpkeep(abi.encode(factory));

    uint256 expectedCount = (registeredA ? 0 : 1) + (registeredB ? 0 : 1);
    assertEq(needed, expectedCount > 0, 'unexpected upkeepNeeded');
    if (expectedCount == 0) {
      assertEq(performData.length, 0, 'performData should be empty');
      return;
    }

    (address reportedFactory, address[] memory tokens) = abi.decode(
      performData,
      (address, address[])
    );
    assertEq(reportedFactory, factory, 'performData factory mismatch');
    assertEq(tokens.length, expectedCount, 'unexpected stataTokens count');
    if (!registeredA) assertEq(tokens[0], stataA, 'stataA should be first');
    if (!registeredB) assertEq(tokens[expectedCount - 1], stataB, 'stataB should be last');
  }

  function test_checkUpkeep_flagsToken_whenOnlyLaterRewardUnregistered() public {
    address otherReward = makeAddr('otherReward');
    _mockStataTokens(factory, _one(stataA));
    _mockRewards(stataA, _two(reward, otherReward));
    _mockRegistered(stataA, reward, true);
    _mockRegistered(stataA, otherReward, false);

    (bool needed, ) = robot.checkUpkeep(abi.encode(factory));
    assertTrue(needed, 'unregistered second reward not detected');
  }

  function test_checkUpkeep_returnsFalse_whenAllOfSeveralRewardsRegistered() public {
    address otherReward = makeAddr('otherReward');
    _mockStataTokens(factory, _one(stataA));
    _mockRewards(stataA, _two(reward, otherReward));
    _mockRegistered(stataA, reward, true);
    _mockRegistered(stataA, otherReward, true);

    (bool needed, ) = robot.checkUpkeep(abi.encode(factory));
    assertFalse(needed, 'upkeep needed with every reward registered');
  }

  function test_checkUpkeep_capsAtMaxActions_skippingRegisteredTokens() public {
    uint256 maxActions = robot.MAX_ACTIONS();
    uint256 total = maxActions * 2 + 3;
    address[] memory tokens = new address[](total);
    address[] memory expected = new address[](maxActions);
    uint256 count = 0;
    for (uint256 i = 0; i < total; i++) {
      tokens[i] = makeAddr(string.concat('stata', vm.toString(i)));
      _mockStata(tokens[i], vm.toString(i));
      _mockRewards(tokens[i], _one(reward));
      // Every other token is already registered and must be skipped.
      bool needsRefresh = i % 2 == 1;
      _mockRegistered(tokens[i], reward, !needsRefresh);
      if (needsRefresh && count < maxActions) expected[count++] = tokens[i];
    }
    _mockStataTokens(factory, tokens);

    (bool needed, bytes memory performData) = robot.checkUpkeep(abi.encode(factory));
    assertTrue(needed, 'upkeep should be needed');
    (, address[] memory picked) = abi.decode(performData, (address, address[]));
    assertEq(picked, expected, 'should pick the first MAX_ACTIONS tokens needing a refresh');
  }

  function test_onReport_refreshes_whenAnyoneCalls() public {
    _mockRewards(stataA, _one(reward));
    _mockRegistered(stataA, reward, false);

    vm.expectCall(stataA, abi.encodeWithSelector(IERC20AaveLM.refreshRewardTokens.selector));
    vm.expectEmit(address(robot));
    emit IRefreshRewardsReceiver.RefreshSucceeded(stataA);

    vm.prank(anyone);
    robot.onReport('', abi.encode(factory, _one(stataA)));
  }

  function test_onReport_skipsStaleToken_andRefreshesRest() public {
    _mockRewards(stataA, _one(reward));
    _mockRewards(stataB, _one(reward));
    _mockRegistered(stataA, reward, true);
    _mockRegistered(stataB, reward, false);

    vm.expectCall(stataA, abi.encodeWithSelector(IERC20AaveLM.refreshRewardTokens.selector), 0);
    vm.expectCall(stataB, abi.encodeWithSelector(IERC20AaveLM.refreshRewardTokens.selector), 1);

    vm.recordLogs();
    vm.prank(anyone);
    robot.onReport('', abi.encode(factory, _two(stataA, stataB)));

    Vm.Log[] memory logs = vm.getRecordedLogs();
    assertEq(logs.length, 1, 'expected a single RefreshSucceeded');
    assertEq(logs[0].topics[0], IRefreshRewardsReceiver.RefreshSucceeded.selector, 'wrong event');
    assertEq(
      address(uint160(uint256(logs[0].topics[1]))),
      stataB,
      'event for the wrong stataToken'
    );
  }

  function test_onReport_skipsStataTokenNotFromFactory() public {
    address spoofed = makeAddr('spoofed');
    _mockStata(spoofed, 'spoofed');
    // The factory maps the spoofed token's underlying to a different stataToken.
    vm.mockCall(
      factory,
      abi.encodeWithSelector(IStataTokenFactory.getStataToken.selector, _underlying('spoofed')),
      abi.encode(stataA)
    );
    _mockRewards(spoofed, _one(reward));
    _mockRegistered(spoofed, reward, false);
    _mockRewards(stataB, _one(reward));
    _mockRegistered(stataB, reward, false);

    vm.expectCall(spoofed, abi.encodeWithSelector(IERC20AaveLM.refreshRewardTokens.selector), 0);
    vm.expectCall(stataB, abi.encodeWithSelector(IERC20AaveLM.refreshRewardTokens.selector), 1);

    vm.prank(anyone);
    robot.onReport('', abi.encode(factory, _two(spoofed, stataB)));
  }

  function test_onReport_revertsWith_ConditionsNotMet_whenNothingToRefresh() public {
    _mockRewards(stataA, _one(reward));
    _mockRegistered(stataA, reward, true);

    vm.prank(anyone);
    vm.expectRevert(IRefreshRewardsReceiver.ConditionsNotMet.selector);
    robot.onReport('', abi.encode(factory, _one(stataA)));
  }

  function test_onReport_revertsWith_ConditionsNotMet_whenFactoryDisabled() public {
    _mockRewards(stataA, _one(reward));
    _mockRegistered(stataA, reward, false);

    vm.prank(guardian);
    robot.disableFactory(factory);

    vm.expectCall(stataA, abi.encodeWithSelector(IERC20AaveLM.refreshRewardTokens.selector), 0);
    vm.prank(anyone);
    vm.expectRevert(IRefreshRewardsReceiver.ConditionsNotMet.selector);
    robot.onReport('', abi.encode(factory, _one(stataA)));
  }

  function test_onReport_revertsWith_ConditionsNotMet_whenEmptyBatch() public {
    vm.prank(anyone);
    vm.expectRevert(IRefreshRewardsReceiver.ConditionsNotMet.selector);
    robot.onReport('', abi.encode(factory, new address[](0)));
  }

  function test_onReport_revertsWith_ConditionsNotMet_whenOnlySpoofedTokens() public {
    address spoofed = makeAddr('spoofed');
    _mockStata(spoofed, 'spoofed');
    vm.mockCall(
      factory,
      abi.encodeWithSelector(IStataTokenFactory.getStataToken.selector, _underlying('spoofed')),
      abi.encode(stataA)
    );
    _mockRewards(spoofed, _one(reward));
    _mockRegistered(spoofed, reward, false);

    vm.expectCall(spoofed, abi.encodeWithSelector(IERC20AaveLM.refreshRewardTokens.selector), 0);
    vm.prank(anyone);
    vm.expectRevert(IRefreshRewardsReceiver.ConditionsNotMet.selector);
    robot.onReport('', abi.encode(factory, _one(spoofed)));
  }

  function test_enableFactory() public {
    address otherFactory = makeAddr('otherFactory');

    vm.expectEmit(address(robot));
    emit IRefreshRewardsReceiver.FactoryStatusUpdated(otherFactory, true);

    vm.prank(owner);
    robot.enableFactory(otherFactory);
    assertTrue(robot.isFactoryEnabled(otherFactory), 'factory not enabled');
  }

  function test_enableFactory_revertsWith_OwnableUnauthorized() public {
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
    robot.enableFactory(makeAddr('otherFactory'));
  }

  function test_enableFactory_revertsWhenCalledByGuardian() public {
    vm.prank(guardian);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
    robot.enableFactory(makeAddr('otherFactory'));
  }

  function test_enableFactory_revertsWith_InvalidFactory() public {
    vm.prank(owner);
    vm.expectRevert(IRefreshRewardsReceiver.InvalidFactory.selector);
    robot.enableFactory(address(0));
  }

  function test_enableFactory_revertsWith_FactoryStatusUnchanged() public {
    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(IRefreshRewardsReceiver.FactoryStatusUnchanged.selector, factory, true)
    );
    robot.enableFactory(factory);
  }

  function test_disableFactory_byOwner() public {
    vm.expectEmit(address(robot));
    emit IRefreshRewardsReceiver.FactoryStatusUpdated(factory, false);

    vm.prank(owner);
    robot.disableFactory(factory);
    assertFalse(robot.isFactoryEnabled(factory), 'factory still enabled');
  }

  function test_disableFactory_byGuardian() public {
    vm.prank(guardian);
    robot.disableFactory(factory);
    assertFalse(robot.isFactoryEnabled(factory), 'factory still enabled');
  }

  function test_disableFactory_revertsWith_NotOwnerOrGuardian() public {
    vm.prank(bob);
    vm.expectRevert(
      abi.encodeWithSelector(IWithGuardian.OnlyGuardianOrOwnerInvalidCaller.selector, bob)
    );
    robot.disableFactory(factory);
  }

  function test_disableFactory_revertsWith_FactoryStatusUnchanged() public {
    address otherFactory = makeAddr('otherFactory');

    vm.prank(guardian);
    vm.expectRevert(
      abi.encodeWithSelector(
        IRefreshRewardsReceiver.FactoryStatusUnchanged.selector,
        otherFactory,
        false
      )
    );
    robot.disableFactory(otherFactory);
  }

  function test_rescueGuardian_isOwner() public view {
    assertEq(robot.rescueGuardian(), owner, 'rescue guardian is not the owner');
  }

  function test_rescueToken_revertsWith_OnlyRescueGuardian() public {
    vm.prank(guardian);
    vm.expectRevert(IRescuable.OnlyRescueGuardian.selector);
    robot.rescueToken(makeAddr('token'), bob, 100);
  }

  /// @dev Mocks a stataToken deployed by `factory`: its aToken, underlying, incentives
  /// controller, the factory lookup back to it, and a no-op `refreshRewardTokens`.
  function _mockStata(address stata, string memory id) internal {
    address aToken = makeAddr(string.concat('aToken', id));
    address underlying = _underlying(id);
    vm.mockCall(
      stata,
      abi.encodeWithSelector(IERC4626StataToken.aToken.selector),
      abi.encode(aToken)
    );
    vm.mockCall(stata, abi.encodeWithSelector(IERC4626.asset.selector), abi.encode(underlying));
    vm.mockCall(
      stata,
      abi.encodeWithSelector(IStataToken.INCENTIVES_CONTROLLER.selector),
      abi.encode(controller)
    );
    vm.mockCall(
      factory,
      abi.encodeWithSelector(IStataTokenFactory.getStataToken.selector, underlying),
      abi.encode(stata)
    );
    vm.mockCall(stata, abi.encodeWithSelector(IERC20AaveLM.refreshRewardTokens.selector), '');
  }

  function _mockStataTokens(address factory_, address[] memory tokens) internal {
    vm.mockCall(
      factory_,
      abi.encodeWithSelector(IStataTokenFactory.getStataTokens.selector),
      abi.encode(tokens)
    );
  }

  function _mockRewards(address stata, address[] memory rewards) internal {
    vm.mockCall(
      controller,
      abi.encodeWithSelector(
        IRewardsDistributor.getRewardsByAsset.selector,
        IStataToken(stata).aToken()
      ),
      abi.encode(rewards)
    );
  }

  function _mockRegistered(address stata, address reward_, bool isRegistered) internal {
    vm.mockCall(
      stata,
      abi.encodeWithSelector(IERC20AaveLM.isRegisteredRewardToken.selector, reward_),
      abi.encode(isRegistered)
    );
  }

  function _underlying(string memory id) internal returns (address) {
    return makeAddr(string.concat('underlying', id));
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
