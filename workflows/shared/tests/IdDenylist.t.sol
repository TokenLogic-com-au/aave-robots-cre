// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from 'forge-std/Test.sol';

import {Ownable} from 'openzeppelin-contracts/contracts/access/Ownable.sol';
import {IWithGuardian} from 'solidity-utils/contracts/access-control/interfaces/IWithGuardian.sol';

import {IWorkflowsBase} from 'aave-cre/IWorkflowsBase.sol';
import {IIdDenylist} from 'aave-cre/IIdDenylist.sol';

import {MockIdDenylistRobot} from './helpers/MockRobots.sol';

contract IdDenylistTest is Test {
  MockIdDenylistRobot internal robot;

  address internal owner = makeAddr('owner');
  address internal guardian = makeAddr('guardian');
  address internal anyone = makeAddr('anyone');

  function setUp() public {
    robot = new MockIdDenylistRobot(address(0), 0, owner, guardian);
  }

  function test_fuzz_disableId_byOwnerOrGuardian(bool byOwner, uint256 id) public {
    vm.expectEmit(address(robot));
    emit IIdDenylist.IdDisabled(id, true);
    vm.prank(byOwner ? owner : guardian);
    robot.disableId(id);

    assertTrue(robot.isIdDisabled(id), 'id should be disabled');
    assertFalse(robot.isDisabled(), 'robot should stay enabled');
  }

  function test_disableId_revertsWith_OnlyGuardianOrOwnerInvalidCaller() public {
    vm.expectRevert(
      abi.encodeWithSelector(IWithGuardian.OnlyGuardianOrOwnerInvalidCaller.selector, anyone)
    );
    vm.prank(anyone);
    robot.disableId(1);
  }

  function test_disableId_revertsWith_IdStatusUnchanged() public {
    _disable(1);
    vm.expectRevert(abi.encodeWithSelector(IIdDenylist.IdStatusUnchanged.selector, 1));
    vm.prank(guardian);
    robot.disableId(1);
  }

  function test_enableId_byOwner() public {
    _disable(1);
    vm.expectEmit(address(robot));
    emit IIdDenylist.IdDisabled(1, false);
    vm.prank(owner);
    robot.enableId(1);

    assertFalse(robot.isIdDisabled(1), 'id should be enabled');
  }

  function test_fuzz_enableId_revertsWith_OwnableUnauthorizedAccount(bool byGuardian) public {
    _disable(1);
    address caller = byGuardian ? guardian : anyone;
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
    vm.prank(caller);
    robot.enableId(1);
  }

  function test_enableId_revertsWith_IdStatusUnchanged() public {
    vm.expectRevert(abi.encodeWithSelector(IIdDenylist.IdStatusUnchanged.selector, 1));
    vm.prank(owner);
    robot.enableId(1);
  }

  function test_globalAndIdSwitches_areIndependent() public {
    _disable(1);
    vm.prank(guardian);
    robot.disableAutomation();
    vm.prank(owner);
    robot.enableAutomation();

    assertFalse(robot.isDisabled(), 'robot should be enabled');
    assertTrue(robot.isIdDisabled(1), 'id should stay disabled');
  }

  function test_checkUpkeep_skipsDisabledIds() public {
    _disable(2);
    (bool needed, bytes memory performData) = robot.checkUpkeep(abi.encode(_ids(1, 2, 3)));
    assertTrue(needed, 'upkeep should be needed');
    assertEq(performData, abi.encode(_ids(1, 3)), 'disabled id should be skipped');
  }

  function test_onReport_skipsDisabledIds() public {
    _disable(2);
    vm.recordLogs();
    robot.onReport('', abi.encode(_ids(1, 2, 3)));

    Vm.Log[] memory logs = vm.getRecordedLogs();
    assertEq(logs.length, 2, 'only enabled ids should execute');
    assertEq(abi.decode(logs[0].data, (uint256)), 1, 'first id mismatch');
    assertEq(abi.decode(logs[1].data, (uint256)), 3, 'second id mismatch');
  }

  function test_onReport_revertsWith_AutomationIsDisabled() public {
    vm.prank(guardian);
    robot.disableAutomation();
    vm.expectRevert(IWorkflowsBase.AutomationIsDisabled.selector);
    robot.onReport('', abi.encode(_ids(1, 2, 3)));
  }

  function _disable(uint256 id) internal {
    vm.prank(guardian);
    robot.disableId(id);
  }

  function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
    ids = new uint256[](2);
    (ids[0], ids[1]) = (a, b);
  }

  function _ids(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory ids) {
    ids = new uint256[](3);
    (ids[0], ids[1], ids[2]) = (a, b, c);
  }
}
