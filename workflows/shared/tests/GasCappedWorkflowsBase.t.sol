// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';

import {IWithGuardian} from 'solidity-utils/contracts/access-control/interfaces/IWithGuardian.sol';
import {AggregatorInterface} from 'aave-v3-origin/contracts/dependencies/chainlink/AggregatorInterface.sol';

import {IWorkflowsBase} from 'aave-cre/IWorkflowsBase.sol';
import {IGasCappedWorkflowsBase} from 'aave-cre/IGasCappedWorkflowsBase.sol';

import {MockGasCappedRobot} from './helpers/MockRobots.sol';

contract GasCappedWorkflowsBaseTest is Test {
  uint256 internal constant MAX_GAS_PRICE = 150 gwei;

  MockGasCappedRobot internal robot;

  address internal owner = makeAddr('owner');
  address internal guardian = makeAddr('guardian');
  address internal anyone = makeAddr('anyone');
  address internal oracle = makeAddr('gas-price-oracle');

  function setUp() public {
    _mockGasPrice(10 gwei);
    robot = new MockGasCappedRobot(oracle, MAX_GAS_PRICE, owner, guardian);
  }

  function test_constructor_setsState() public view {
    assertEq(robot.GAS_PRICE_ORACLE(), oracle, 'oracle mismatch');
    assertEq(robot.getMaxGasPrice(), MAX_GAS_PRICE, 'max gas price mismatch');
  }

  function test_constructor_emitsMaxGasPriceSet() public {
    vm.expectEmit();
    emit IGasCappedWorkflowsBase.MaxGasPriceSet(MAX_GAS_PRICE);
    new MockGasCappedRobot(oracle, MAX_GAS_PRICE, owner, guardian);
  }

  function test_constructor_withoutOracle_isUncapped() public {
    robot = new MockGasCappedRobot(address(0), 0, owner, guardian);
    assertEq(robot.GAS_PRICE_ORACLE(), address(0), 'oracle should be unset');
    assertEq(robot.getMaxGasPrice(), 0, 'max gas price should be unset');
    assertTrue(robot.isGasPriceInRange(), 'uncapped should always be in range');
  }

  function test_constructor_revertsWith_InvalidMaxGasPrice() public {
    vm.expectRevert(IGasCappedWorkflowsBase.InvalidMaxGasPrice.selector);
    new MockGasCappedRobot(oracle, 0, owner, guardian);
  }

  function test_constructor_revertsWith_GasPriceCapNotSupported() public {
    vm.expectRevert(IGasCappedWorkflowsBase.GasPriceCapNotSupported.selector);
    new MockGasCappedRobot(address(0), MAX_GAS_PRICE, owner, guardian);
  }

  function test_fuzz_setMaxGasPrice_byOwnerOrGuardian(bool byOwner, uint256 maxGasPrice) public {
    vm.assume(maxGasPrice != 0 && maxGasPrice != MAX_GAS_PRICE);
    vm.expectEmit(address(robot));
    emit IGasCappedWorkflowsBase.MaxGasPriceSet(maxGasPrice);
    vm.prank(byOwner ? owner : guardian);
    robot.setMaxGasPrice(maxGasPrice);

    assertEq(robot.getMaxGasPrice(), maxGasPrice, 'max gas price not updated');
  }

  function test_setMaxGasPrice_revertsWith_OnlyGuardianOrOwnerInvalidCaller() public {
    vm.expectRevert(
      abi.encodeWithSelector(IWithGuardian.OnlyGuardianOrOwnerInvalidCaller.selector, anyone)
    );
    vm.prank(anyone);
    robot.setMaxGasPrice(1);
  }

  function test_setMaxGasPrice_revertsWith_InvalidMaxGasPrice() public {
    vm.expectRevert(IGasCappedWorkflowsBase.InvalidMaxGasPrice.selector);
    vm.prank(owner);
    robot.setMaxGasPrice(0);
  }

  function test_setMaxGasPrice_revertsWith_MaxGasPriceUnchanged() public {
    vm.expectRevert(IGasCappedWorkflowsBase.MaxGasPriceUnchanged.selector);
    vm.prank(owner);
    robot.setMaxGasPrice(MAX_GAS_PRICE);
  }

  function test_setMaxGasPrice_revertsWith_GasPriceCapNotSupported() public {
    robot = new MockGasCappedRobot(address(0), 0, owner, guardian);
    vm.expectRevert(IGasCappedWorkflowsBase.GasPriceCapNotSupported.selector);
    vm.prank(owner);
    robot.setMaxGasPrice(1);
  }

  function test_fuzz_isGasPriceInRange(int256 answer) public {
    _mockGasPrice(answer);
    assertEq(
      robot.isGasPriceInRange(),
      answer >= 0 && uint256(answer) <= MAX_GAS_PRICE,
      'range mismatch'
    );
  }

  function test_fuzz_checkUpkeep_respectsGasPriceCap(uint256 gasPrice) public {
    gasPrice = bound(gasPrice, 0, 2 * MAX_GAS_PRICE);
    _mockGasPrice(int256(gasPrice));
    (bool needed, ) = robot.checkUpkeep('');
    assertEq(needed, gasPrice <= MAX_GAS_PRICE, 'upkeep should follow the cap');
  }

  function test_checkUpkeep_returnsFalse_whenDisabled_withoutReadingOracle() public {
    vm.prank(guardian);
    robot.disableAutomation();
    vm.mockCallRevert(
      oracle,
      abi.encodeWithSelector(AggregatorInterface.latestAnswer.selector),
      ''
    );

    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed, 'upkeep should not be needed');
  }

  function test_onReport_ignoresGasPriceCap() public {
    _mockGasPrice(int256(MAX_GAS_PRICE + 1));
    vm.expectEmit(address(robot));
    emit MockGasCappedRobot.Reported(hex'01');
    robot.onReport('', hex'01');
  }

  function test_onReport_revertsWith_AutomationIsDisabled() public {
    vm.prank(guardian);
    robot.disableAutomation();
    vm.expectRevert(IWorkflowsBase.AutomationIsDisabled.selector);
    robot.onReport('', hex'01');
  }

  function _mockGasPrice(int256 answer) internal {
    vm.mockCall(
      oracle,
      abi.encodeWithSelector(AggregatorInterface.latestAnswer.selector),
      abi.encode(answer)
    );
  }
}
