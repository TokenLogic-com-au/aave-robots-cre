// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {AaveV2Avalanche} from 'aave-address-book/AaveV2Avalanche.sol';
import {AaveV3Avalanche} from 'aave-address-book/AaveV3Avalanche.sol';

import {IProofOfReserveReceiver, IProofOfReserveExecutor} from '../src/IProofOfReserveReceiver.sol';
import {ProofOfReserveReceiverHarness} from './helpers/ProofOfReserveReceiverHarness.sol';

contract ProofOfReserveReceiverForkTest is Test {
  ProofOfReserveReceiverHarness internal robot;
  address internal owner = makeAddr('fork-owner');
  address internal guardian = makeAddr('fork-guardian');
  address internal anyone = makeAddr('fork-anyone');

  address internal executorV2 = AaveV2Avalanche.PROOF_OF_RESERVE;
  address internal executorV3 = AaveV3Avalanche.PROOF_OF_RESERVE;

  function setUp() public {
    vm.createSelectFork(vm.envString('RPC_AVALANCHE'));
    address[] memory executors = new address[](2);
    executors[0] = executorV2;
    executors[1] = executorV3;
    robot = new ProofOfReserveReceiverHarness(owner, guardian, executors);
  }

  /// Checks the local `IProofOfReserveExecutor` matches the deployed executors.
  function test_fork_readPath_interfacesMatch() public view {
    IProofOfReserveExecutor(executorV2).areAllReservesBacked();
    IProofOfReserveExecutor(executorV2).isEmergencyActionPossible();
    IProofOfReserveExecutor(executorV3).areAllReservesBacked();
    IProofOfReserveExecutor(executorV3).isEmergencyActionPossible();
  }

  function test_fork_checkUpkeep_doesNotRevert() public view {
    robot.checkUpkeep(abi.encode(executorV2));
    robot.checkUpkeep(abi.encode(executorV3));
  }

  function test_fork_onReport_revertsNotPossible_whenReservesBacked() public {
    address executor = _findBackedExecutor();
    require(executor != address(0), 'no backed executor found on the fork');

    vm.prank(anyone);
    vm.expectRevert(IProofOfReserveReceiver.EmergencyActionNotPossible.selector);
    robot.onReport('', abi.encode(executor));
  }

  function _findBackedExecutor() internal view returns (address) {
    if (!robot.shouldExecute(executorV2)) return executorV2;
    if (!robot.shouldExecute(executorV3)) return executorV3;
    return address(0);
  }
}
