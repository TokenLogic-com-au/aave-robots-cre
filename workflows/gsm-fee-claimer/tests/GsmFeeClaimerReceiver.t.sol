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
  uint256 internal constant MIN_FEES = 1000e18;

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
    (bool needed, bytes memory performData) = robot.checkUpkeep(_checkData(gsmA, gsmB, 0));
    assertFalse(needed, 'upkeep needed with no fees');
    assertEq(performData, '', 'performData should be empty');
  }

  function test_checkUpkeep_returnsOnlyGsmsWithFees() public {
    _mockFees(gsmA, 0);
    _mockFees(gsmB, 5e18);
    (bool needed, bytes memory performData) = robot.checkUpkeep(_checkData(gsmA, gsmB, 0));
    assertTrue(needed, 'upkeep not needed with fees');
    _assertReport(performData, gsmB);
  }

  function test_checkUpkeep_keepsOrder_whenAllHaveFees() public {
    _mockFees(gsmA, 1);
    _mockFees(gsmB, 2);
    (, bytes memory performData) = robot.checkUpkeep(_checkData(gsmA, gsmB, 0));
    address[] memory gsms = abi.decode(performData, (address[]));
    assertEq(gsms.length, 2, 'wrong number of gsms');
    assertEq(gsms[0], gsmA, 'wrong first gsm');
    assertEq(gsms[1], gsmB, 'wrong second gsm');
  }

  function test_checkUpkeep_skipsGsm_belowMinFees() public {
    _mockFees(gsmA, MIN_FEES - 1);
    _mockFees(gsmB, MIN_FEES);
    (bool needed, bytes memory performData) = robot.checkUpkeep(_checkData(gsmA, gsmB, MIN_FEES));
    assertTrue(needed, 'upkeep not needed at the threshold');
    _assertReport(performData, gsmB);
  }

  function test_checkUpkeep_returnsFalse_whenAllBelowMinFees() public {
    _mockFees(gsmA, MIN_FEES - 1);
    _mockFees(gsmB, 1);
    (bool needed, ) = robot.checkUpkeep(_checkData(gsmA, gsmB, MIN_FEES));
    assertFalse(needed, 'upkeep needed below the threshold');
  }

  function test_checkUpkeep_skipsGsm_whenReadReverts() public {
    vm.mockCallRevert(gsmA, abi.encodeWithSelector(IGsmFees.getAccruedFees.selector), 'boom');
    _mockFees(gsmB, 5e18);
    (bool needed, bytes memory performData) = robot.checkUpkeep(_checkData(gsmA, gsmB, 0));
    assertTrue(needed, 'upkeep not needed while one gsm has fees');
    _assertReport(performData, gsmB);
  }

  function test_checkUpkeep_skipsGsm_whenNoCode() public {
    address noCode = address(0xdead);
    assertEq(noCode.code.length, 0, 'fixture should have no code');
    _mockFees(gsmB, 5e18);
    (bool needed, bytes memory performData) = robot.checkUpkeep(_checkData(noCode, gsmB, 0));
    assertTrue(needed, 'upkeep not needed while one gsm has fees');
    _assertReport(performData, gsmB);
  }

  function test_checkUpkeep_skipsGsm_whenReadReturnsNoData() public {
    // Code that stops immediately: the call succeeds with empty return data, which a
    // plain `try` would not survive.
    address noData = address(0xbeef);
    vm.etch(noData, hex'00');
    _mockFees(gsmB, 5e18);
    (bool needed, bytes memory performData) = robot.checkUpkeep(_checkData(noData, gsmB, 0));
    assertTrue(needed, 'upkeep not needed while one gsm has fees');
    _assertReport(performData, gsmB);
  }

  function test_checkUpkeep_returnsFalse_whenDisabled() public {
    _mockFees(gsmA, 5e18);
    vm.prank(owner);
    robot.setDisabled(true);
    (bool needed, bytes memory performData) = robot.checkUpkeep(_checkData(gsmA, gsmB, 0));
    assertFalse(needed, 'upkeep needed while disabled');
    assertEq(performData, '', 'performData should be empty');
  }

  function testFuzz_checkUpkeep_neededIffAnyFeesAtLeastMin(
    uint256 feesA,
    uint256 feesB,
    uint256 minFees
  ) public {
    _mockFees(gsmA, feesA);
    _mockFees(gsmB, feesB);
    (bool needed, ) = robot.checkUpkeep(_checkData(gsmA, gsmB, minFees));
    bool expected = (feesA > 0 && feesA >= minFees) || (feesB > 0 && feesB >= minFees);
    assertEq(needed, expected, 'upkeep decision mismatch');
  }

  function test_onReport_distributesEachGsm_whenAnyoneCalls() public {
    _mockDistribute(gsmA);
    _mockDistribute(gsmB);
    vm.expectCall(gsmA, abi.encodeWithSelector(IGsmFees.distributeFeesToTreasury.selector), 1);
    vm.expectCall(gsmB, abi.encodeWithSelector(IGsmFees.distributeFeesToTreasury.selector), 1);

    vm.prank(anyone);
    robot.onReport('', _report(gsmA, gsmB));
  }

  function test_onReport_ignoresMetadataContents() public {
    _mockDistribute(gsmA);
    _mockDistribute(gsmB);
    vm.prank(anyone);
    robot.onReport(abi.encodePacked(keccak256('workflow'), bytes10('name')), _report(gsmA, gsmB));
  }

  function test_onReport_isNoOp_whenReportEmpty() public {
    vm.prank(anyone);
    robot.onReport('', abi.encode(new address[](0)));
  }

  function test_onReport_bubblesGsmRevert() public {
    _mockDistribute(gsmA);
    vm.mockCallRevert(
      gsmB,
      abi.encodeWithSelector(IGsmFees.distributeFeesToTreasury.selector),
      'boom'
    );
    vm.prank(anyone);
    vm.expectRevert(bytes('boom'));
    robot.onReport('', _report(gsmA, gsmB));
  }

  function test_onReport_revertsWith_Disabled() public {
    _mockDistribute(gsmA);
    vm.prank(guardian);
    robot.setDisabled(true);

    vm.prank(anyone);
    vm.expectRevert(IGsmFeeClaimerReceiver.Disabled.selector);
    robot.onReport('', _report(gsmA, gsmB));
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

    (bool needed, ) = robot.checkUpkeep(_checkData(gsmA, gsmB, 0));
    assertTrue(needed, 'upkeep not resumed');
    vm.prank(anyone);
    robot.onReport('', _report(gsmA, gsmA));
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

  function _checkData(address a, address b, uint256 minFees) internal pure returns (bytes memory) {
    return abi.encode(_pair(a, b), minFees);
  }

  function _report(address a, address b) internal pure returns (bytes memory) {
    return abi.encode(_pair(a, b));
  }

  function _pair(address a, address b) internal pure returns (address[] memory gsms) {
    gsms = new address[](2);
    gsms[0] = a;
    gsms[1] = b;
  }

  function _assertReport(bytes memory performData, address expected) internal pure {
    address[] memory gsms = abi.decode(performData, (address[]));
    assertEq(gsms.length, 1, 'wrong number of gsms');
    assertEq(gsms[0], expected, 'wrong gsm');
  }

  function _mockFees(address gsm, uint256 fees) internal {
    vm.mockCall(gsm, abi.encodeWithSelector(IGsmFees.getAccruedFees.selector), abi.encode(fees));
  }

  function _mockDistribute(address gsm) internal {
    vm.mockCall(gsm, abi.encodeWithSelector(IGsmFees.distributeFeesToTreasury.selector), '');
  }
}
