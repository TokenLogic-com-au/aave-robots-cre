// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {IWithGuardian} from 'solidity-utils/contracts/access-control/interfaces/IWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

import {ProofOfReserveReceiver} from '../src/ProofOfReserveReceiver.sol';
import {IProofOfReserveReceiver, IProofOfReserveExecutor} from '../src/IProofOfReserveReceiver.sol';

contract ProofOfReserveReceiverTest is Test {
  ProofOfReserveReceiver internal robot;

  address internal owner;
  address internal guardian;
  address internal bob;
  address internal anyone;

  address internal executor;

  function setUp() public {
    owner = makeAddr('owner');
    guardian = makeAddr('guardian');
    bob = makeAddr('bob');
    anyone = makeAddr('anyone');
    executor = makeAddr('executor');

    robot = new ProofOfReserveReceiver(owner, guardian);
  }

  function test_constructor_setsOwnerAndGuardian() public view {
    assertEq(robot.owner(), owner);
    assertEq(robot.guardian(), guardian);
  }

  function test_supportsInterface() public view {
    assertTrue(robot.supportsInterface(type(IReceiver).interfaceId));
    assertTrue(robot.supportsInterface(type(IAaveCREReceiver).interfaceId));
    assertTrue(robot.supportsInterface(type(IERC165).interfaceId));
    assertFalse(robot.supportsInterface(0xffffffff));
  }

  function test_checkUpkeep_returnsFalse_whenAllReservesBacked() public {
    _mockExecutor(executor, ExecutorState({allBacked: true, possible: true}));
    (bool needed, ) = robot.checkUpkeep(abi.encode(executor));
    assertFalse(needed);
  }

  function test_checkUpkeep_returnsFalse_whenActionNotPossible() public {
    _mockExecutor(executor, ExecutorState({allBacked: false, possible: false}));
    (bool needed, ) = robot.checkUpkeep(abi.encode(executor));
    assertFalse(needed);
  }

  function test_checkUpkeep_returnsExecutor_whenUnbackedAndPossible() public {
    _mockExecutor(executor, ExecutorState({allBacked: false, possible: true}));
    (bool needed, bytes memory performData) = robot.checkUpkeep(abi.encode(executor));
    assertTrue(needed);
    assertEq(abi.decode(performData, (address)), executor);
  }

  function test_checkUpkeep_returnsFalse_whenDisabled() public {
    _mockExecutor(executor, ExecutorState({allBacked: false, possible: true}));
    vm.prank(owner);
    robot.setDisabled(executor, true);

    (bool needed, ) = robot.checkUpkeep(abi.encode(executor));
    assertFalse(needed);
  }

  function test_checkUpkeep_returnsFalse_whenExecutorZero() public view {
    (bool needed, ) = robot.checkUpkeep(abi.encode(address(0)));
    assertFalse(needed);
  }

  function test_onReport_executes_whenAnyoneCalls() public {
    _mockExecutor(executor, ExecutorState({allBacked: false, possible: true}));

    vm.expectCall(
      executor,
      abi.encodeWithSelector(IProofOfReserveExecutor.executeEmergencyAction.selector)
    );
    vm.expectEmit(address(robot));
    emit IProofOfReserveReceiver.EmergencyActionExecuted(executor);

    vm.prank(anyone);
    robot.onReport('', abi.encode(executor));
  }

  function test_onReport_revertsWith_EmergencyActionNotPossible_whenBacked() public {
    _mockExecutor(executor, ExecutorState({allBacked: true, possible: true}));

    vm.prank(anyone);
    vm.expectRevert(IProofOfReserveReceiver.EmergencyActionNotPossible.selector);
    robot.onReport('', abi.encode(executor));
  }

  function test_onReport_revertsWith_EmergencyActionNotPossible_whenDisabled() public {
    _mockExecutor(executor, ExecutorState({allBacked: false, possible: true}));
    vm.prank(guardian);
    robot.setDisabled(executor, true);

    vm.prank(anyone);
    vm.expectRevert(IProofOfReserveReceiver.EmergencyActionNotPossible.selector);
    robot.onReport('', abi.encode(executor));
  }

  function test_setDisabled_byOwner() public {
    vm.expectEmit(address(robot));
    emit IProofOfReserveReceiver.ExecutorDisabled(executor, true);

    vm.prank(owner);
    robot.setDisabled(executor, true);
    assertTrue(robot.isDisabled(executor));
  }

  function test_setDisabled_byGuardian() public {
    vm.prank(guardian);
    robot.setDisabled(executor, true);
    assertTrue(robot.isDisabled(executor));
  }

  function test_setDisabled_revertsWith_NotOwnerOrGuardian() public {
    vm.prank(bob);
    vm.expectRevert(
      abi.encodeWithSelector(IWithGuardian.OnlyGuardianOrOwnerInvalidCaller.selector, bob)
    );
    robot.setDisabled(executor, true);
  }

  struct ExecutorState {
    bool allBacked;
    bool possible;
  }

  function _mockExecutor(address executor_, ExecutorState memory s) internal {
    vm.mockCall(
      executor_,
      abi.encodeWithSelector(IProofOfReserveExecutor.areAllReservesBacked.selector),
      abi.encode(s.allBacked)
    );
    vm.mockCall(
      executor_,
      abi.encodeWithSelector(IProofOfReserveExecutor.isEmergencyActionPossible.selector),
      abi.encode(s.possible)
    );
    vm.mockCall(
      executor_,
      abi.encodeWithSelector(IProofOfReserveExecutor.executeEmergencyAction.selector),
      ''
    );
  }
}
