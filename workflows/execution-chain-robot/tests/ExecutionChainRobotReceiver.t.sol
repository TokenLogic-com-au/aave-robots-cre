// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, Vm} from 'forge-std/Test.sol';

import {IPayloadsControllerCore} from 'aave-address-book/governance-v3/IPayloadsControllerCore.sol';

import {ExecutionChainRobotReceiver} from '../src/ExecutionChainRobotReceiver.sol';
import {IExecutionChainRobotReceiver} from '../src/IExecutionChainRobotReceiver.sol';

contract ExecutionChainRobotReceiverTest is Test {
  uint40 internal constant NOW = 1_800_000_000;
  uint40 internal constant DELAY = 1 days;
  uint40 internal constant GRACE_PERIOD = 7 days;
  uint256 internal constant MAX_GAS_PRICE = 150 gwei;

  ExecutionChainRobotReceiver internal robot;
  ExecutionChainRobotReceiver internal cappedRobot;

  address internal owner;
  address internal guardian;
  address internal anyone;
  address internal controller;
  address internal oracle;

  function setUp() public {
    owner = makeAddr('owner');
    guardian = makeAddr('guardian');
    anyone = makeAddr('anyone');
    controller = makeAddr('payloadsController');
    oracle = makeAddr('gasPriceOracle');

    vm.warp(NOW);
    robot = new ExecutionChainRobotReceiver(controller, address(0), 0, owner, guardian);
    cappedRobot = new ExecutionChainRobotReceiver(
      controller,
      oracle,
      MAX_GAS_PRICE,
      owner,
      guardian
    );
  }

  function test_constructor_setsState() public view {
    assertEq(robot.owner(), owner, 'owner mismatch');
    assertEq(robot.guardian(), guardian, 'guardian mismatch');
    assertEq(address(robot.PAYLOADS_CONTROLLER()), controller, 'controller mismatch');
    assertEq(robot.GAS_PRICE_ORACLE(), address(0), 'uncapped robot has an oracle');
    assertEq(robot.getMaxGasPrice(), 0, 'uncapped robot has a cap');
    assertEq(cappedRobot.GAS_PRICE_ORACLE(), oracle, 'oracle mismatch');
    assertEq(cappedRobot.getMaxGasPrice(), MAX_GAS_PRICE, 'max gas price mismatch');
  }

  function test_constructor_revertsWith_InvalidPayloadsController() public {
    vm.expectRevert(IExecutionChainRobotReceiver.InvalidPayloadsController.selector);
    new ExecutionChainRobotReceiver(address(0), address(0), 0, owner, guardian);
  }

  function test_constants() public view {
    assertEq(robot.MAX_ACTIONS(), 5, 'unexpected MAX_ACTIONS');
    assertEq(robot.MAX_SKIP(), 20, 'unexpected MAX_SKIP');
    assertEq(robot.MAX_SCANNED_PAYLOADS(), 100, 'unexpected MAX_SCANNED_PAYLOADS');
    assertEq(robot.MAX_STATE_READ_GAS(), 150_000, 'unexpected MAX_STATE_READ_GAS');
  }

  function test_checkUpkeep_returnsFalse_whenNoPayloads() public {
    _mockPayloadsCount(0);

    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertFalse(needed, 'upkeep needed without payloads');
    assertEq(performData.length, 0, 'performData should be empty');
  }

  /// A single payload, over every state, around its execution time, enabled or disabled.
  function test_fuzz_checkUpkeep_singlePayload(
    uint8 stateSeed,
    int256 secondsFromExecutionTime,
    bool disabled
  ) public {
    IPayloadsControllerCore.PayloadState state = IPayloadsControllerCore.PayloadState(
      bound(stateSeed, 0, uint8(type(IPayloadsControllerCore.PayloadState).max))
    );
    int256 offset = bound(secondsFromExecutionTime, -2 days, 2 days);
    uint40 queuedAt = uint40(uint256(int256(uint256(NOW)) - int256(uint256(DELAY)) - offset));

    _mockPayloadsCount(1);
    _mockPayload(0, state, queuedAt);
    if (disabled) {
      vm.prank(guardian);
      robot.disableId(0);
    }

    (bool needed, bytes memory performData) = robot.checkUpkeep('');

    bool expected = !disabled && state == IPayloadsControllerCore.PayloadState.Queued && offset > 0;
    assertEq(needed, expected, 'unexpected upkeepNeeded');
    if (expected) assertEq(_decode(performData), _ids(0), 'unexpected payload ids');
    else assertEq(performData.length, 0, 'performData should be empty');
  }

  function test_checkUpkeep_returnsExecutablePayloadsOldestFirst() public {
    _mockPayloadsCount(4);
    _mockExecutable(0);
    _mockPayload(1, IPayloadsControllerCore.PayloadState.Executed, _executableQueuedAt());
    _mockExecutable(2);
    _mockExecutable(3);

    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertTrue(needed, 'upkeep should be needed');
    assertEq(_decode(performData), _ids(0, 2, 3), 'unexpected payload ids');
  }

  function test_checkUpkeep_capsAtMaxActions_keepingTheNewest() public {
    uint40 total = uint40(robot.MAX_ACTIONS()) + 3;
    _mockPayloadsCount(total);
    for (uint40 i = 0; i < total; i++) _mockExecutable(i);

    (, bytes memory performData) = robot.checkUpkeep('');
    uint40[] memory ids = _decode(performData);
    assertEq(ids.length, robot.MAX_ACTIONS(), 'should return MAX_ACTIONS payloads');
    for (uint256 i = 0; i < ids.length; i++) {
      assertEq(ids[i], total - robot.MAX_ACTIONS() + i, 'should keep the newest, oldest first');
    }
  }

  /// An executable payload below `nonExecutable` newer ones (in the timelock or in a final
  /// state) is found iff they are at most MAX_SKIP.
  function test_fuzz_checkUpkeep_maxSkip(uint256 nonExecutable, uint8 stateSeed) public {
    nonExecutable = bound(nonExecutable, 0, robot.MAX_SKIP() + 5);
    uint256 kind = bound(stateSeed, 0, 3);
    uint40 total = uint40(nonExecutable) + 1;
    _mockPayloadsCount(total);
    _mockExecutable(0);
    for (uint40 i = 1; i < total; i++) {
      if (kind == 0) _mockNotExecutable(i);
      else _mockPayload(i, IPayloadsControllerCore.PayloadState(kind + 2), _executableQueuedAt());
    }

    (bool needed, ) = robot.checkUpkeep('');
    assertEq(needed, nonExecutable <= robot.MAX_SKIP(), 'unexpected upkeepNeeded');
  }

  /// Anyone can create payloads: `Created` ones don't count toward MAX_SKIP and are never
  /// loaded in full, so junk payloads can't hide a queued one within MAX_SCANNED_PAYLOADS.
  function test_fuzz_checkUpkeep_createdPayloadsDontCountAsSkipped(uint256 junk) public {
    junk = bound(junk, robot.MAX_SKIP() + 1, robot.MAX_SCANNED_PAYLOADS() - 1);
    uint40 total = uint40(junk) + 1;
    _mockPayloadsCount(total);
    _mockExecutable(0);
    for (uint40 i = 1; i < total; i++) _mockCreated(i);

    vm.expectCall(
      controller,
      abi.encodeCall(IPayloadsControllerCore.getPayloadById, (total - 1)),
      0
    );
    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertTrue(needed, 'queued payload hidden by created ones');
    assertEq(_decode(performData), _ids(0), 'unexpected payload ids');
  }

  /// Payloads whose state read fails (e.g. runs out of MAX_STATE_READ_GAS) are skipped uncounted.
  function test_checkUpkeep_unreadablePayloadsDontCountAsSkipped() public {
    uint40 total = uint40(robot.MAX_SKIP()) + 10;
    _mockPayloadsCount(total);
    _mockExecutable(0);
    for (uint40 i = 1; i < total; i++) {
      vm.mockCallRevert(
        controller,
        abi.encodeCall(IPayloadsControllerCore.getPayloadState, (i)),
        ''
      );
    }

    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertTrue(needed, 'queued payload hidden by unreadable ones');
    assertEq(_decode(performData), _ids(0), 'unexpected payload ids');
  }

  /// The scan stops after MAX_SCANNED_PAYLOADS payloads, whatever their state.
  function test_fuzz_checkUpkeep_maxScannedPayloads(uint256 junk) public {
    uint256 maxScanned = robot.MAX_SCANNED_PAYLOADS();
    junk = bound(junk, maxScanned - 5, maxScanned + 5);
    uint40 total = uint40(junk) + 1;
    _mockPayloadsCount(total);
    _mockExecutable(0);
    for (uint40 i = 1; i < total; i++) _mockCreated(i);

    vm.expectCall(
      controller,
      abi.encodeWithSelector(IPayloadsControllerCore.getPayloadState.selector),
      uint64(junk + 1 > maxScanned ? maxScanned : junk + 1)
    );
    (bool needed, ) = robot.checkUpkeep('');
    assertEq(needed, junk < maxScanned, 'unexpected upkeepNeeded');
  }

  function test_checkUpkeep_executablePayloadResetsSkipCount() public {
    uint40 gap = uint40(robot.MAX_SKIP());
    uint40 total = 2 * gap + 2;
    _mockPayloadsCount(total);
    _mockExecutable(0);
    for (uint40 i = 1; i <= gap; i++) _mockNotExecutable(i);
    _mockExecutable(gap + 1);
    for (uint40 i = gap + 2; i < total; i++) _mockNotExecutable(i);

    (, bytes memory performData) = robot.checkUpkeep('');
    assertEq(_decode(performData), _ids(0, gap + 1), 'both payloads should be found');
  }

  function test_checkUpkeep_disabledPayloadsDontCountAsSkipped() public {
    uint40 total = uint40(robot.MAX_SKIP()) + 10;
    _mockPayloadsCount(total);
    _mockExecutable(0);
    for (uint40 i = 1; i < total; i++) {
      _mockExecutable(i);
      vm.prank(guardian);
      robot.disableId(i);
    }

    (, bytes memory performData) = robot.checkUpkeep('');
    assertEq(_decode(performData), _ids(0), 'payload below disabled ones should be found');
  }

  function test_fuzz_onReport(
    bool executableA,
    bool executableB,
    bool disabledA,
    bool disabledB
  ) public {
    _mockPayloadsCount(2);
    _mockExecutable(0, executableA);
    _mockExecutable(1, executableB);
    _mockExecutePayload(0);
    _mockExecutePayload(1);
    vm.startPrank(guardian);
    if (disabledA) robot.disableId(0);
    if (disabledB) robot.disableId(1);
    vm.stopPrank();

    bool runA = executableA && !disabledA;
    bool runB = executableB && !disabledB;
    vm.expectCall(
      controller,
      abi.encodeCall(IPayloadsControllerCore.executePayload, (0)),
      runA ? 1 : 0
    );
    vm.expectCall(
      controller,
      abi.encodeCall(IPayloadsControllerCore.executePayload, (1)),
      runB ? 1 : 0
    );
    if (!runA && !runB)
      vm.expectRevert(IExecutionChainRobotReceiver.NoActionCanBePerformed.selector);

    vm.recordLogs();
    vm.prank(anyone);
    robot.onReport('', abi.encode(_ids(0, 1)));

    if (!runA && !runB) return;
    Vm.Log[] memory logs = vm.getRecordedLogs();
    assertEq(logs.length, (runA ? 1 : 0) + (runB ? 1 : 0), 'one ActionSucceeded per execution');
    for (uint256 i = 0; i < logs.length; i++) {
      assertEq(
        logs[i].topics[0],
        IExecutionChainRobotReceiver.ActionSucceeded.selector,
        'wrong event'
      );
    }
    if (runA) assertEq(uint256(logs[0].topics[1]), 0, 'payload 0 should be executed first');
  }

  function test_onReport_executesInReportOrder() public {
    _mockExecutable(0);
    _mockExecutable(1);
    _mockExecutePayload(0);
    _mockExecutePayload(1);

    vm.expectEmit(address(robot));
    emit IExecutionChainRobotReceiver.ActionSucceeded(1);
    vm.expectEmit(address(robot));
    emit IExecutionChainRobotReceiver.ActionSucceeded(0);

    vm.prank(anyone);
    robot.onReport('', abi.encode(_ids(1, 0)));
  }

  function test_onReport_revertsWith_NoActionCanBePerformed_whenEmptyBatch() public {
    vm.prank(anyone);
    vm.expectRevert(IExecutionChainRobotReceiver.NoActionCanBePerformed.selector);
    robot.onReport('', abi.encode(new uint40[](0)));
  }

  function test_onReport_bubblesUpExecutePayloadRevert() public {
    _mockExecutable(0);
    vm.mockCallRevert(
      controller,
      abi.encodeCall(IPayloadsControllerCore.executePayload, (0)),
      bytes('payload failed')
    );

    vm.prank(anyone);
    vm.expectRevert(bytes('payload failed'));
    robot.onReport('', abi.encode(_ids(0)));
  }

  function _executableQueuedAt() internal pure returns (uint40) {
    return NOW - DELAY - 1;
  }

  function _mockExecutable(uint40 payloadId) internal {
    _mockPayload(payloadId, IPayloadsControllerCore.PayloadState.Queued, _executableQueuedAt());
  }

  /// @dev Queued but still in its timelock.
  function _mockNotExecutable(uint40 payloadId) internal {
    _mockPayload(payloadId, IPayloadsControllerCore.PayloadState.Queued, NOW - DELAY);
  }

  function _mockExecutable(uint40 payloadId, bool executable) internal {
    if (executable) _mockExecutable(payloadId);
    else _mockNotExecutable(payloadId);
  }

  function _mockPayload(
    uint40 payloadId,
    IPayloadsControllerCore.PayloadState state,
    uint40 queuedAt
  ) internal {
    IPayloadsControllerCore.Payload memory payload;
    payload.state = state;
    payload.queuedAt = queuedAt;
    payload.delay = DELAY;
    payload.gracePeriod = GRACE_PERIOD;
    vm.mockCall(
      controller,
      abi.encodeCall(IPayloadsControllerCore.getPayloadById, (payloadId)),
      abi.encode(payload)
    );
    vm.mockCall(
      controller,
      abi.encodeCall(IPayloadsControllerCore.getPayloadState, (payloadId)),
      abi.encode(state)
    );
  }

  function _mockCreated(uint40 payloadId) internal {
    _mockPayload(payloadId, IPayloadsControllerCore.PayloadState.Created, 0);
  }

  function _mockPayloadsCount(uint40 count) internal {
    vm.mockCall(
      controller,
      abi.encodeCall(IPayloadsControllerCore.getPayloadsCount, ()),
      abi.encode(count)
    );
  }

  function _mockExecutePayload(uint40 payloadId) internal {
    vm.mockCall(
      controller,
      abi.encodeCall(IPayloadsControllerCore.executePayload, (payloadId)),
      ''
    );
  }

  function _decode(bytes memory performData) internal pure returns (uint40[] memory) {
    return abi.decode(performData, (uint40[]));
  }

  function _ids(uint40 a) internal pure returns (uint40[] memory arr) {
    arr = new uint40[](1);
    arr[0] = a;
  }

  function _ids(uint40 a, uint40 b) internal pure returns (uint40[] memory arr) {
    arr = new uint40[](2);
    arr[0] = a;
    arr[1] = b;
  }

  function _ids(uint40 a, uint40 b, uint40 c) internal pure returns (uint40[] memory arr) {
    arr = new uint40[](3);
    arr[0] = a;
    arr[1] = b;
    arr[2] = c;
  }

  function assertEq(uint40[] memory a, uint40[] memory b, string memory err) internal pure {
    assertEq(a.length, b.length, string.concat(err, ': length'));
    for (uint256 i = 0; i < a.length; i++) assertEq(uint256(a[i]), uint256(b[i]), err);
  }
}
