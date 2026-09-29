// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {Ownable} from 'openzeppelin-contracts/contracts/access/Ownable.sol';
import {IWithGuardian} from 'solidity-utils/contracts/access-control/interfaces/IWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';
import {IRescuable} from 'aave-v4/interfaces/IRescuable.sol';

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

    robot = new ProofOfReserveReceiver(owner, guardian, new address[](0));
  }

  function test_constructor_setsOwnerAndGuardian() public view {
    assertEq(robot.owner(), owner, 'owner mismatch');
    assertEq(robot.guardian(), guardian, 'guardian mismatch');
  }

  function test_constructor_enablesInitialExecutors() public {
    address otherExecutor = makeAddr('otherExecutor');
    address[] memory executors = new address[](2);
    executors[0] = executor;
    executors[1] = otherExecutor;

    vm.expectEmit();
    emit IProofOfReserveReceiver.ExecutorStatusUpdated(executor, true);
    vm.expectEmit();
    emit IProofOfReserveReceiver.ExecutorStatusUpdated(otherExecutor, true);

    ProofOfReserveReceiver deployed = new ProofOfReserveReceiver(owner, guardian, executors);

    assertTrue(deployed.isExecutorEnabled(executor), 'executor not enabled');
    assertTrue(deployed.isExecutorEnabled(otherExecutor), 'other executor not enabled');
  }

  function test_constructor_revertsWith_InvalidExecutor() public {
    address[] memory executors = new address[](1);

    vm.expectRevert(IProofOfReserveReceiver.InvalidExecutor.selector);
    new ProofOfReserveReceiver(owner, guardian, executors);
  }

  function test_constructor_revertsWith_ExecutorStatusUnchanged_whenDuplicated() public {
    address[] memory executors = new address[](2);
    executors[0] = executor;
    executors[1] = executor;

    vm.expectRevert(
      abi.encodeWithSelector(
        IProofOfReserveReceiver.ExecutorStatusUnchanged.selector,
        executor,
        true
      )
    );
    new ProofOfReserveReceiver(owner, guardian, executors);
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

  function test_executor_notEnabledByDefault() public view {
    assertFalse(robot.isExecutorEnabled(executor), 'executor enabled by default');
  }

  function test_fuzz_checkUpkeep_whenEnabled(bool allBacked, bool possible) public {
    _enable(executor);
    _mockExecutor(executor, ExecutorState({allBacked: allBacked, possible: possible}));

    (bool needed, bytes memory performData) = robot.checkUpkeep(abi.encode(executor));

    bool expected = !allBacked && possible;
    assertEq(needed, expected, 'unexpected upkeepNeeded');
    if (expected) {
      assertEq(abi.decode(performData, (address)), executor, 'performData is not the executor');
    } else {
      assertEq(performData.length, 0, 'performData should be empty');
    }
  }

  function test_fuzz_checkUpkeep_returnsFalse_whenNotEnabled(bool allBacked, bool possible) public {
    _mockExecutor(executor, ExecutorState({allBacked: allBacked, possible: possible}));

    (bool needed, bytes memory performData) = robot.checkUpkeep(abi.encode(executor));
    assertFalse(needed, 'upkeep needed for non-enabled executor');
    assertEq(performData.length, 0, 'performData should be empty');
  }

  function test_fuzz_checkUpkeep_returnsFalse_whenDisabledAfterEnabled(
    bool allBacked,
    bool possible
  ) public {
    _enable(executor);
    vm.prank(guardian);
    robot.disableExecutor(executor);
    _mockExecutor(executor, ExecutorState({allBacked: allBacked, possible: possible}));

    (bool needed, ) = robot.checkUpkeep(abi.encode(executor));
    assertFalse(needed, 'upkeep needed for disabled executor');
  }

  function test_checkUpkeep_returnsFalse_whenExecutorZero() public view {
    (bool needed, ) = robot.checkUpkeep(abi.encode(address(0)));
    assertFalse(needed, 'upkeep needed for zero executor');
  }

  function test_onReport_executes_whenAnyoneCalls() public {
    _enable(executor);
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

  function test_fuzz_onReport_revertsWith_EmergencyActionNotPossible_whenNotActionable(
    bool allBacked,
    bool possible
  ) public {
    vm.assume(allBacked || !possible);
    _enable(executor);
    _mockExecutor(executor, ExecutorState({allBacked: allBacked, possible: possible}));

    vm.expectCall(
      executor,
      abi.encodeWithSelector(IProofOfReserveExecutor.executeEmergencyAction.selector),
      0
    );
    vm.prank(anyone);
    vm.expectRevert(IProofOfReserveReceiver.EmergencyActionNotPossible.selector);
    robot.onReport('', abi.encode(executor));
  }

  function test_fuzz_onReport_revertsWith_EmergencyActionNotPossible_whenNotEnabled(
    bool allBacked,
    bool possible
  ) public {
    _mockExecutor(executor, ExecutorState({allBacked: allBacked, possible: possible}));

    vm.expectCall(
      executor,
      abi.encodeWithSelector(IProofOfReserveExecutor.executeEmergencyAction.selector),
      0
    );
    vm.prank(anyone);
    vm.expectRevert(IProofOfReserveReceiver.EmergencyActionNotPossible.selector);
    robot.onReport('', abi.encode(executor));
  }

  function test_enableExecutor() public {
    vm.expectEmit(address(robot));
    emit IProofOfReserveReceiver.ExecutorStatusUpdated(executor, true);

    vm.prank(owner);
    robot.enableExecutor(executor);
    assertTrue(robot.isExecutorEnabled(executor), 'executor not enabled');
  }

  function test_enableExecutor_revertsWith_OwnableUnauthorized() public {
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
    robot.enableExecutor(executor);
  }

  function test_enableExecutor_revertsWhenCalledByGuardian() public {
    vm.prank(guardian);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
    robot.enableExecutor(executor);
  }

  function test_enableExecutor_revertsWith_InvalidExecutor() public {
    vm.prank(owner);
    vm.expectRevert(IProofOfReserveReceiver.InvalidExecutor.selector);
    robot.enableExecutor(address(0));
  }

  function test_enableExecutor_revertsWith_ExecutorStatusUnchanged() public {
    _enable(executor);

    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(
        IProofOfReserveReceiver.ExecutorStatusUnchanged.selector,
        executor,
        true
      )
    );
    robot.enableExecutor(executor);
  }

  function test_disableExecutor_byOwner() public {
    _enable(executor);

    vm.expectEmit(address(robot));
    emit IProofOfReserveReceiver.ExecutorStatusUpdated(executor, false);

    vm.prank(owner);
    robot.disableExecutor(executor);
    assertFalse(robot.isExecutorEnabled(executor), 'executor still enabled');
  }

  function test_disableExecutor_byGuardian() public {
    _enable(executor);

    vm.prank(guardian);
    robot.disableExecutor(executor);
    assertFalse(robot.isExecutorEnabled(executor), 'executor still enabled');
  }

  function test_disableExecutor_revertsWith_NotOwnerOrGuardian() public {
    _enable(executor);

    vm.prank(bob);
    vm.expectRevert(
      abi.encodeWithSelector(IWithGuardian.OnlyGuardianOrOwnerInvalidCaller.selector, bob)
    );
    robot.disableExecutor(executor);
  }

  function test_disableExecutor_revertsWith_ExecutorStatusUnchanged() public {
    vm.prank(guardian);
    vm.expectRevert(
      abi.encodeWithSelector(
        IProofOfReserveReceiver.ExecutorStatusUnchanged.selector,
        executor,
        false
      )
    );
    robot.disableExecutor(executor);
  }

  function test_rescueGuardian_isOwner() public view {
    assertEq(robot.rescueGuardian(), owner, 'rescue guardian is not the owner');
  }

  function test_rescueToken_revertsWith_OnlyRescueGuardian() public {
    address token = makeAddr('token');

    vm.prank(guardian);
    vm.expectRevert(IRescuable.OnlyRescueGuardian.selector);
    robot.rescueToken(token, bob, 100);
  }

  struct ExecutorState {
    bool allBacked;
    bool possible;
  }

  function _enable(address executor_) internal {
    vm.prank(owner);
    robot.enableExecutor(executor_);
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
