// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {IWithGuardian} from 'solidity-utils/contracts/access-control/interfaces/IWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

import {GsmFeeClaimerReceiver} from '../src/GsmFeeClaimerReceiver.sol';
import {IGsmFeeClaimerReceiver, IGsmFees} from '../src/IGsmFeeClaimerReceiver.sol';

contract GsmFeeClaimerReceiverTest is Test {
  GsmFeeClaimerReceiver internal robot;

  address internal owner;
  address internal guardian;
  address internal bob;
  address internal anyone;

  address internal gsmA;
  address internal gsmB;

  function setUp() public {
    owner = makeAddr('owner');
    guardian = makeAddr('guardian');
    bob = makeAddr('bob');
    anyone = makeAddr('anyone');
    gsmA = makeAddr('gsmA');
    gsmB = makeAddr('gsmB');

    robot = new GsmFeeClaimerReceiver(owner, guardian);
  }

  function test_constructor_setsOwnerAndGuardian() public view {
    assertEq(robot.owner(), owner, 'owner not set');
    assertEq(robot.guardian(), guardian, 'guardian not set');
    assertFalse(robot.isDisabled(), 'should start enabled');
  }

  function test_supportsInterface() public view {
    assertTrue(robot.supportsInterface(type(IReceiver).interfaceId), 'IReceiver unsupported');
    assertTrue(
      robot.supportsInterface(type(IAaveCREReceiver).interfaceId),
      'IAaveCREReceiver unsupported'
    );
    assertTrue(robot.supportsInterface(type(IERC165).interfaceId), 'IERC165 unsupported');
    assertFalse(robot.supportsInterface(0xffffffff), 'invalid interface reported supported');
  }

  function test_checkUpkeep_returnsFalse_whenCheckDataEmpty() public view {
    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertFalse(needed, 'upkeep needed with empty checkData');
    assertEq(performData, '', 'performData should be empty');
  }

  function test_checkUpkeep_returnsFalse_whenNoFees() public {
    _mockFees(gsmA, 0);
    _mockFees(gsmB, 0);
    (bool needed, bytes memory performData) = robot.checkUpkeep(_checkData(gsmA, gsmB));
    assertFalse(needed, 'upkeep needed with no fees');
    assertEq(performData, '', 'performData should be empty');
  }

  function test_checkUpkeep_returnsOnlyGsmsWithFees() public {
    _mockFees(gsmA, 0);
    _mockFees(gsmB, 5e18);
    (bool needed, bytes memory performData) = robot.checkUpkeep(_checkData(gsmA, gsmB));
    assertTrue(needed, 'upkeep not needed with fees');
    address[] memory gsms = abi.decode(performData, (address[]));
    assertEq(gsms.length, 1, 'wrong number of gsms');
    assertEq(gsms[0], gsmB, 'wrong gsm');
  }

  function test_checkUpkeep_keepsOrder_whenAllHaveFees() public {
    _mockFees(gsmA, 1);
    _mockFees(gsmB, 2);
    (, bytes memory performData) = robot.checkUpkeep(_checkData(gsmA, gsmB));
    address[] memory gsms = abi.decode(performData, (address[]));
    assertEq(gsms.length, 2, 'wrong number of gsms');
    assertEq(gsms[0], gsmA, 'wrong first gsm');
    assertEq(gsms[1], gsmB, 'wrong second gsm');
  }

  function test_checkUpkeep_skipsGsm_whenReadReverts() public {
    vm.mockCallRevert(gsmA, abi.encodeWithSelector(IGsmFees.getAccruedFees.selector), 'boom');
    _mockFees(gsmB, 5e18);
    (bool needed, bytes memory performData) = robot.checkUpkeep(_checkData(gsmA, gsmB));
    assertTrue(needed, 'upkeep not needed while one gsm has fees');
    address[] memory gsms = abi.decode(performData, (address[]));
    assertEq(gsms.length, 1, 'reverting gsm not skipped');
    assertEq(gsms[0], gsmB, 'wrong gsm');
  }

  function test_checkUpkeep_skipsGsm_whenNoCode() public {
    address noCode = address(0xdead);
    assertEq(noCode.code.length, 0, 'fixture should have no code');
    _mockFees(gsmB, 5e18);
    (bool needed, bytes memory performData) = robot.checkUpkeep(_checkData(noCode, gsmB));
    assertTrue(needed, 'upkeep not needed while one gsm has fees');
    address[] memory gsms = abi.decode(performData, (address[]));
    assertEq(gsms.length, 1, 'code-less address not skipped');
    assertEq(gsms[0], gsmB, 'wrong gsm');
  }

  function test_checkUpkeep_skipsGsm_whenReadReturnsNoData() public {
    // makeAddr accounts carry an EIP-7702 delegation in this forge version: the call
    // succeeds with empty return data, which `try` alone would not survive.
    assertGt(bob.code.length, 0, 'fixture should have delegation code');
    _mockFees(gsmB, 5e18);
    (bool needed, bytes memory performData) = robot.checkUpkeep(_checkData(bob, gsmB));
    assertTrue(needed, 'upkeep not needed while one gsm has fees');
    address[] memory gsms = abi.decode(performData, (address[]));
    assertEq(gsms.length, 1, 'no-data address not skipped');
    assertEq(gsms[0], gsmB, 'wrong gsm');
  }

  function test_checkUpkeep_returnsFalse_whenDisabled() public {
    _mockFees(gsmA, 5e18);
    vm.prank(owner);
    robot.setDisabled(true);
    (bool needed, bytes memory performData) = robot.checkUpkeep(_checkData(gsmA, gsmB));
    assertFalse(needed, 'upkeep needed while disabled');
    assertEq(performData, '', 'performData should be empty');
  }

  function testFuzz_checkUpkeep_neededIffAnyFees(uint256 feesA, uint256 feesB) public {
    _mockFees(gsmA, feesA);
    _mockFees(gsmB, feesB);
    (bool needed, ) = robot.checkUpkeep(_checkData(gsmA, gsmB));
    assertEq(needed, feesA > 0 || feesB > 0, 'upkeep decision mismatch');
  }

  function test_onReport_distributes_whenAnyoneCalls() public {
    _mockFees(gsmA, 5e18);
    _mockFees(gsmB, 7e18);
    _mockDistribute(gsmA);
    _mockDistribute(gsmB);

    vm.expectCall(gsmA, abi.encodeWithSelector(IGsmFees.distributeFeesToTreasury.selector));
    vm.expectCall(gsmB, abi.encodeWithSelector(IGsmFees.distributeFeesToTreasury.selector));
    vm.expectEmit(address(robot));
    emit IGsmFeeClaimerReceiver.FeesDistributed(gsmA, 5e18);
    vm.expectEmit(address(robot));
    emit IGsmFeeClaimerReceiver.FeesDistributed(gsmB, 7e18);

    vm.prank(anyone);
    robot.onReport('', _checkData(gsmA, gsmB));
  }

  function test_onReport_ignoresMetadataContents() public {
    _mockFees(gsmA, 5e18);
    _mockFees(gsmB, 7e18);
    _mockDistribute(gsmA);
    _mockDistribute(gsmB);

    vm.prank(anyone);
    robot.onReport(
      abi.encodePacked(keccak256('workflow'), bytes10('name')),
      _checkData(gsmA, gsmB)
    );
  }

  function test_onReport_distributesOnce_whenGsmRepeated() public {
    _mockFees(gsmA, 5e18);
    // The mock keeps reporting fees after the first distribution, so the second entry
    // is only skipped if the robot re-reads fees per entry; make the re-read return 0.
    vm.mockCall(gsmA, abi.encodeWithSelector(IGsmFees.distributeFeesToTreasury.selector), '');
    vm.mockCalls(
      gsmA,
      abi.encodeWithSelector(IGsmFees.getAccruedFees.selector),
      _feesSequence(5e18, 0)
    );
    vm.expectCall(gsmA, abi.encodeWithSelector(IGsmFees.distributeFeesToTreasury.selector), 1);

    vm.prank(anyone);
    robot.onReport('', _checkData(gsmA, gsmA));
  }

  function test_onReport_skipsGsm_withoutFees() public {
    _mockFees(gsmA, 0);
    _mockFees(gsmB, 7e18);
    _mockDistribute(gsmB);

    vm.expectCall(gsmA, abi.encodeWithSelector(IGsmFees.distributeFeesToTreasury.selector), 0);
    vm.expectCall(gsmB, abi.encodeWithSelector(IGsmFees.distributeFeesToTreasury.selector), 1);

    vm.prank(anyone);
    robot.onReport('', _checkData(gsmA, gsmB));
  }

  function test_onReport_emitsFailure_andContinues_whenDistributeReverts() public {
    _mockFees(gsmA, 5e18);
    _mockFees(gsmB, 7e18);
    vm.mockCallRevert(
      gsmA,
      abi.encodeWithSelector(IGsmFees.distributeFeesToTreasury.selector),
      'boom'
    );
    _mockDistribute(gsmB);

    vm.expectEmit(address(robot));
    emit IGsmFeeClaimerReceiver.FeeDistributionFailed(gsmA, 'boom');
    vm.expectEmit(address(robot));
    emit IGsmFeeClaimerReceiver.FeesDistributed(gsmB, 7e18);

    vm.prank(anyone);
    robot.onReport('', _checkData(gsmA, gsmB));
  }

  function test_onReport_revertsWith_NothingToDistribute_whenNoFees() public {
    _mockFees(gsmA, 0);
    _mockFees(gsmB, 0);

    vm.prank(anyone);
    vm.expectRevert(IGsmFeeClaimerReceiver.NothingToDistribute.selector);
    robot.onReport('', _checkData(gsmA, gsmB));
  }

  function test_onReport_revertsWith_NothingToDistribute_whenAllDistributionsFail() public {
    _mockFees(gsmA, 5e18);
    _mockFees(gsmB, 7e18);
    vm.mockCallRevert(
      gsmA,
      abi.encodeWithSelector(IGsmFees.distributeFeesToTreasury.selector),
      'boom'
    );
    vm.mockCallRevert(
      gsmB,
      abi.encodeWithSelector(IGsmFees.distributeFeesToTreasury.selector),
      'boom'
    );

    vm.prank(anyone);
    vm.expectRevert(IGsmFeeClaimerReceiver.NothingToDistribute.selector);
    robot.onReport('', _checkData(gsmA, gsmB));
  }

  function test_onReport_revertsWith_NothingToDistribute_whenReportEmpty() public {
    vm.prank(anyone);
    vm.expectRevert(IGsmFeeClaimerReceiver.NothingToDistribute.selector);
    robot.onReport('', abi.encode(new address[](0)));
  }

  function test_onReport_revertsWith_Disabled() public {
    _mockFees(gsmA, 5e18);
    _mockDistribute(gsmA);
    vm.prank(guardian);
    robot.setDisabled(true);

    vm.prank(anyone);
    vm.expectRevert(IGsmFeeClaimerReceiver.Disabled.selector);
    robot.onReport('', _checkData(gsmA, gsmB));
  }

  function test_setDisabled_byOwner() public {
    vm.expectEmit(address(robot));
    emit IGsmFeeClaimerReceiver.AutomationDisabled(true);

    vm.prank(owner);
    robot.setDisabled(true);
    assertTrue(robot.isDisabled(), 'not disabled by owner');
  }

  function test_setDisabled_byGuardian() public {
    vm.prank(guardian);
    robot.setDisabled(true);
    assertTrue(robot.isDisabled(), 'not disabled by guardian');
  }

  function test_setDisabled_false_resumesAutomation() public {
    _mockFees(gsmA, 5e18);
    _mockDistribute(gsmA);
    vm.startPrank(owner);
    robot.setDisabled(true);
    robot.setDisabled(false);
    vm.stopPrank();
    assertFalse(robot.isDisabled(), 'still disabled');

    (bool needed, ) = robot.checkUpkeep(_checkData(gsmA, gsmB));
    assertTrue(needed, 'upkeep not resumed');
    vm.prank(anyone);
    robot.onReport('', _checkData(gsmA, gsmB));
  }

  function test_setDisabled_revertsWith_NotOwnerOrGuardian() public {
    vm.prank(bob);
    vm.expectRevert(
      abi.encodeWithSelector(IWithGuardian.OnlyGuardianOrOwnerInvalidCaller.selector, bob)
    );
    robot.setDisabled(true);
  }

  function test_setDisabled_revertsWith_StateUnchanged_whenSameValue() public {
    vm.prank(owner);
    vm.expectRevert(IGsmFeeClaimerReceiver.StateUnchanged.selector);
    robot.setDisabled(false);

    vm.prank(owner);
    robot.setDisabled(true);

    vm.prank(guardian);
    vm.expectRevert(IGsmFeeClaimerReceiver.StateUnchanged.selector);
    robot.setDisabled(true);
  }

  function _checkData(address a, address b) internal pure returns (bytes memory) {
    address[] memory gsms = new address[](2);
    gsms[0] = a;
    gsms[1] = b;
    return abi.encode(gsms);
  }

  function _mockFees(address gsm, uint256 fees) internal {
    vm.mockCall(gsm, abi.encodeWithSelector(IGsmFees.getAccruedFees.selector), abi.encode(fees));
  }

  function _mockDistribute(address gsm) internal {
    vm.mockCall(gsm, abi.encodeWithSelector(IGsmFees.distributeFeesToTreasury.selector), '');
  }

  function _feesSequence(uint256 first, uint256 second) internal pure returns (bytes[] memory) {
    bytes[] memory results = new bytes[](2);
    results[0] = abi.encode(first);
    results[1] = abi.encode(second);
    return results;
  }
}
