// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {AaveV2Avalanche} from 'aave-address-book/AaveV2Avalanche.sol';
import {AaveV3Avalanche} from 'aave-address-book/AaveV3Avalanche.sol';

import {ProofOfReserveReceiver} from '../src/ProofOfReserveReceiver.sol';
import {IProofOfReserveReceiver, IProofOfReserveExecutor} from '../src/IProofOfReserveReceiver.sol';

contract ProofOfReserveReceiverForkTest is Test {
  ProofOfReserveReceiver internal robot;
  address internal owner = makeAddr('fork-owner');
  address internal guardian = makeAddr('fork-guardian');
  address internal anyone = makeAddr('fork-anyone');

  address internal executorV2 = AaveV2Avalanche.PROOF_OF_RESERVE;
  address internal executorV3 = AaveV3Avalanche.PROOF_OF_RESERVE;

  function setUp() public {
    vm.createSelectFork(vm.envString('RPC_AVALANCHE'));
    robot = new ProofOfReserveReceiver(owner, guardian);
  }

  /// The minimal local interface must match the real deployed ABIs — exercise
  /// the read path checkUpkeep relies on, against the real executors.
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
    if (executor == address(0)) {
      vm.skip(true);
    }
    vm.prank(anyone);
    vm.expectRevert(IProofOfReserveReceiver.EmergencyActionNotPossible.selector);
    robot.onReport('', abi.encode(executor));
  }

  function _findBackedExecutor() internal view returns (address) {
    if (!_shouldExecute(executorV2)) return executorV2;
    if (!_shouldExecute(executorV3)) return executorV3;
    return address(0);
  }

  function _shouldExecute(address executor) internal view returns (bool) {
    IProofOfReserveExecutor e = IProofOfReserveExecutor(executor);
    return !e.areAllReservesBacked() && e.isEmergencyActionPossible();
  }
}
