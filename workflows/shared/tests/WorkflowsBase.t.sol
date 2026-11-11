// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';

import {Ownable} from 'openzeppelin-contracts/contracts/access/Ownable.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';
import {IWithGuardian} from 'solidity-utils/contracts/access-control/interfaces/IWithGuardian.sol';
import {IRescuable} from 'aave-v4/interfaces/IRescuable.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';
import {IWorkflowsBase} from 'aave-cre/IWorkflowsBase.sol';

import {MockRobot} from './helpers/MockRobots.sol';
import {MockToken} from './helpers/MockToken.sol';

contract WorkflowsBaseTest is Test {
  MockRobot internal robot;

  address internal owner = makeAddr('owner');
  address internal guardian = makeAddr('guardian');
  address internal anyone = makeAddr('anyone');

  function setUp() public {
    robot = new MockRobot(owner, guardian);
  }

  function test_constructor_setsState() public view {
    assertEq(robot.owner(), owner, 'owner mismatch');
    assertEq(robot.guardian(), guardian, 'guardian mismatch');
    assertEq(robot.rescueGuardian(), owner, 'rescue guardian should be the owner');
    assertFalse(robot.isDisabled(), 'should start enabled');
  }

  function test_supportsInterface() public view {
    assertTrue(robot.supportsInterface(type(IReceiver).interfaceId), 'IReceiver');
    assertTrue(robot.supportsInterface(type(IAaveCREReceiver).interfaceId), 'IAaveCREReceiver');
    assertTrue(robot.supportsInterface(type(IWorkflowsBase).interfaceId), 'IWorkflowsBase');
    assertTrue(robot.supportsInterface(type(IERC165).interfaceId), 'IERC165');
    assertFalse(robot.supportsInterface(0xffffffff), 'invalid interface id');
  }

  function test_onReport_forwardsToRobot() public {
    vm.expectEmit(address(robot));
    emit MockRobot.Reported(hex'aa', hex'bb');
    vm.prank(anyone);
    robot.onReport(hex'aa', hex'bb');
  }

  function test_checkUpkeep_forwardsToRobot() public view {
    (bool needed, bytes memory performData) = robot.checkUpkeep(hex'beef');
    assertTrue(needed, 'upkeep should be needed');
    assertEq(performData, hex'beef', 'performData mismatch');
  }

  function test_fuzz_disableAutomation_byOwnerOrGuardian(bool byOwner) public {
    vm.expectEmit(address(robot));
    emit IWorkflowsBase.AutomationDisabled(true);
    vm.prank(byOwner ? owner : guardian);
    robot.disableAutomation();

    assertTrue(robot.isDisabled(), 'should be disabled');
  }

  function test_disableAutomation_revertsWith_OnlyGuardianOrOwnerInvalidCaller() public {
    vm.expectRevert(
      abi.encodeWithSelector(IWithGuardian.OnlyGuardianOrOwnerInvalidCaller.selector, anyone)
    );
    vm.prank(anyone);
    robot.disableAutomation();
  }

  function test_disableAutomation_revertsWith_StateUnchanged() public {
    _disable();
    vm.expectRevert(IWorkflowsBase.StateUnchanged.selector);
    vm.prank(guardian);
    robot.disableAutomation();
  }

  function test_enableAutomation_byOwner() public {
    _disable();
    vm.expectEmit(address(robot));
    emit IWorkflowsBase.AutomationDisabled(false);
    vm.prank(owner);
    robot.enableAutomation();

    assertFalse(robot.isDisabled(), 'should be enabled');
  }

  function test_fuzz_enableAutomation_revertsWith_OwnableUnauthorizedAccount(
    bool byGuardian
  ) public {
    _disable();
    address caller = byGuardian ? guardian : anyone;
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
    vm.prank(caller);
    robot.enableAutomation();
  }

  function test_enableAutomation_revertsWith_StateUnchanged() public {
    vm.expectRevert(IWorkflowsBase.StateUnchanged.selector);
    vm.prank(owner);
    robot.enableAutomation();
  }

  function test_checkUpkeep_returnsFalse_whenDisabled() public {
    _disable();
    (bool needed, bytes memory performData) = robot.checkUpkeep(hex'beef');
    assertFalse(needed, 'upkeep should not be needed');
    assertEq(performData.length, 0, 'performData should be empty');
  }

  function test_onReport_revertsWith_AutomationIsDisabled() public {
    _disable();
    vm.expectRevert(IWorkflowsBase.AutomationIsDisabled.selector);
    robot.onReport('', hex'bb');
  }

  function test_rescueToken_byOwner() public {
    MockToken token = new MockToken();
    token.mint(address(robot), 100);

    vm.prank(owner);
    robot.rescueToken(address(token), anyone, 100);
    assertEq(token.balanceOf(anyone), 100, 'tokens not rescued');
  }

  function test_rescueNative_byOwner() public {
    vm.deal(address(robot), 1 ether);

    vm.prank(owner);
    robot.rescueNative(anyone, 1 ether);
    assertEq(anyone.balance, 1 ether, 'native not rescued');
  }

  function test_fuzz_rescueToken_revertsWith_OnlyRescueGuardian(bool byGuardian) public {
    vm.expectRevert(IRescuable.OnlyRescueGuardian.selector);
    vm.prank(byGuardian ? guardian : anyone);
    robot.rescueToken(address(1), anyone, 1);
  }

  function _disable() internal {
    vm.prank(guardian);
    robot.disableAutomation();
  }
}
