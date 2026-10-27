// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, Vm} from 'forge-std/Test.sol';

import {AggregatorInterface} from 'aave-v3-origin/contracts/dependencies/chainlink/AggregatorInterface.sol';
import {IGovernanceCore} from 'aave-address-book/governance-v3/IGovernanceCore.sol';
import {PayloadsControllerUtils} from 'aave-address-book/governance-v3/PayloadsControllerUtils.sol';

import {GovernanceChainRobotReceiver} from '../src/GovernanceChainRobotReceiver.sol';
import {IGovernanceChainRobotReceiver} from '../src/IGovernanceChainRobotReceiver.sol';
import {GovernanceChainRobotReceiverHarness} from './helpers/GovernanceChainRobotReceiverHarness.sol';
import {MockGovernance} from './helpers/MockGovernance.sol';

contract GovernanceChainRobotReceiverTest is Test {
  uint256 internal constant NOW = 1_800_000_000;
  uint24 internal constant VOTING_COOLDOWN = 1 days;
  uint256 internal constant QUEUE_COOLDOWN = 1 hours;
  uint56 internal constant MIN_PROPOSITION_POWER = 80_000;
  uint256 internal constant MAX_GAS_PRICE = 150 gwei;
  uint256 internal constant GAS_PRICE = 10 gwei;

  GovernanceChainRobotReceiverHarness internal robot;
  MockGovernance internal gov;

  address internal owner = makeAddr('owner');
  address internal guardian = makeAddr('guardian');
  address internal anyone = makeAddr('anyone');
  address internal creator = makeAddr('creator');
  address internal oracle = makeAddr('gas-price-oracle');

  function setUp() public {
    vm.warp(NOW);
    gov = new MockGovernance();
    gov.setVotingConfig(
      PayloadsControllerUtils.AccessControl.Level_1,
      IGovernanceCore.VotingConfig({
        coolDownBeforeVotingStart: VOTING_COOLDOWN,
        votingDuration: 3 days,
        yesThreshold: 320_000,
        yesNoDifferential: 80_000,
        minPropositionPower: MIN_PROPOSITION_POWER
      })
    );
    gov.setCooldownPeriod(QUEUE_COOLDOWN);
    gov.setPropositionPower(creator, _minPower() + 1);
    _mockGasPrice(int256(GAS_PRICE));

    robot = new GovernanceChainRobotReceiverHarness(
      address(gov),
      oracle,
      MAX_GAS_PRICE,
      owner,
      guardian
    );
  }

  function test_constructor_setsState() public view {
    assertEq(address(robot.GOVERNANCE()), address(gov), 'governance mismatch');
    assertEq(robot.GAS_PRICE_ORACLE(), oracle, 'oracle mismatch');
    assertEq(robot.getMaxGasPrice(), MAX_GAS_PRICE, 'max gas price mismatch');
    assertEq(robot.owner(), owner, 'owner mismatch');
    assertEq(robot.guardian(), guardian, 'guardian mismatch');
    assertEq(robot.rescueGuardian(), owner, 'rescue guardian should be the owner');
  }

  function test_fuzz_constructor_revertsWith_InvalidAddress(bool zeroGovernance) public {
    vm.expectRevert(IGovernanceChainRobotReceiver.InvalidAddress.selector);
    new GovernanceChainRobotReceiver(
      zeroGovernance ? address(0) : address(gov),
      zeroGovernance ? oracle : address(0),
      zeroGovernance ? MAX_GAS_PRICE : 0,
      owner,
      guardian
    );
  }

  function test_constants() public view {
    assertEq(robot.MAX_ACTIONS(), 5, 'unexpected MAX_ACTIONS');
    assertEq(robot.MAX_SKIP(), 20, 'unexpected MAX_SKIP');
  }

  function test_checkUpkeep_returnsFalse_whenGasPriceAboveCap() public {
    _mockGasPrice(int256(MAX_GAS_PRICE + 1));
    _activatable(0);

    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed, 'gas price cap not applied');
  }

  function test_checkUpkeep_returnsFalse_whenAutomationDisabled() public {
    _activatable(0);
    vm.prank(guardian);
    robot.disableAutomation();

    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed, 'global switch not applied');
  }

  // --- predicates ---

  function test_fuzz_isProposalInFinalState(uint8 rawState) public view {
    IGovernanceCore.State state = _toState(rawState);
    assertEq(
      robot.isProposalInFinalState(state),
      state == IGovernanceCore.State.Executed ||
        state == IGovernanceCore.State.Failed ||
        state == IGovernanceCore.State.Cancelled ||
        state == IGovernanceCore.State.Expired,
      'unexpected final state'
    );
  }

  function test_fuzz_canVotingBeActivated(uint8 rawState, uint256 elapsed) public view {
    IGovernanceCore.State state = _toState(rawState);
    elapsed = bound(elapsed, 0, 2 * VOTING_COOLDOWN);
    IGovernanceCore.Proposal memory p = _proposal(state, uint40(NOW - elapsed));

    assertEq(
      robot.canVotingBeActivated(p),
      state == IGovernanceCore.State.Created && elapsed > VOTING_COOLDOWN,
      'unexpected canVotingBeActivated'
    );
  }

  function test_fuzz_canProposalBeExecuted(uint8 rawState, uint256 elapsed) public view {
    IGovernanceCore.State state = _toState(rawState);
    elapsed = bound(elapsed, 0, 2 * QUEUE_COOLDOWN);
    IGovernanceCore.Proposal memory p = _proposal(state, uint40(NOW - 10 days));
    p.queuingTime = uint40(NOW - elapsed);

    assertEq(
      robot.canProposalBeExecuted(p),
      state == IGovernanceCore.State.Queued && elapsed >= QUEUE_COOLDOWN,
      'unexpected canProposalBeExecuted'
    );
  }

  function test_fuzz_canProposalBeCancelled(uint8 rawState, uint256 power) public {
    IGovernanceCore.State state = _toState(rawState);
    power = bound(power, 0, 2 * _minPower());
    gov.setPropositionPower(creator, power);
    IGovernanceCore.Proposal memory p = _proposal(state, uint40(NOW));

    bool open = state == IGovernanceCore.State.Created ||
      state == IGovernanceCore.State.Active ||
      state == IGovernanceCore.State.Queued;
    assertEq(
      robot.canProposalBeCancelled(p),
      open && power <= _minPower(),
      'unexpected canProposalBeCancelled'
    );
  }

  // --- checkUpkeep ---

  function test_checkUpkeep_returnsFalse_whenNoProposals() public view {
    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertFalse(needed, 'upkeep needed without proposals');
    assertEq(performData.length, 0, 'performData should be empty');
  }

  /// One proposal over every state / timing / power combination: checks the selected action
  /// (cancel, then activate, then execute) and that `onReport` performs it.
  function test_fuzz_checkUpkeep_selectsAction(
    uint8 rawState,
    bool votingCooldownPassed,
    bool queueCooldownPassed,
    bool powerTooLow
  ) public {
    IGovernanceCore.State state = _toState(rawState);
    gov.setProposal(0, state, uint40(NOW - VOTING_COOLDOWN - (votingCooldownPassed ? 1 : 0)));
    gov.setCreator(0, creator);
    gov.setQueuingTime(0, uint40(NOW - QUEUE_COOLDOWN + (queueCooldownPassed ? 0 : 1)));
    gov.setPropositionPower(creator, powerTooLow ? _minPower() : _minPower() + 1);

    bool open = state == IGovernanceCore.State.Created ||
      state == IGovernanceCore.State.Active ||
      state == IGovernanceCore.State.Queued;
    bool cancel = open && powerTooLow;
    bool activate = !cancel && state == IGovernanceCore.State.Created && votingCooldownPassed;
    bool execute = !cancel && state == IGovernanceCore.State.Queued && queueCooldownPassed;

    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertEq(needed, cancel || activate || execute, 'unexpected upkeepNeeded');
    if (!needed) {
      assertEq(performData.length, 0, 'performData should be empty');
      return;
    }

    IGovernanceChainRobotReceiver.ActionWithId[] memory actions = _decode(performData);
    assertEq(actions.length, 1, 'expected a single action');
    assertEq(actions[0].id, 0, 'wrong proposal');
    IGovernanceChainRobotReceiver.ProposalAction expectedAction = cancel
      ? IGovernanceChainRobotReceiver.ProposalAction.PerformCancel
      : activate
        ? IGovernanceChainRobotReceiver.ProposalAction.PerformActivateVoting
        : IGovernanceChainRobotReceiver.ProposalAction.PerformExecute;
    assertEq(uint8(actions[0].action), uint8(expectedAction), 'wrong action');

    vm.prank(anyone);
    robot.onReport('', performData);
    IGovernanceCore.State expectedState = cancel
      ? IGovernanceCore.State.Cancelled
      : activate
        ? IGovernanceCore.State.Active
        : IGovernanceCore.State.Executed;
    assertEq(uint8(_state(0)), uint8(expectedState), 'action not performed');
  }

  function test_checkUpkeep_capsAtMaxActions_newestFirst() public {
    uint256 total = robot.MAX_ACTIONS() + 2;
    for (uint256 i = 0; i < total; i++) _activatable(i);

    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertTrue(needed, 'upkeep should be needed');
    IGovernanceChainRobotReceiver.ActionWithId[] memory actions = _decode(performData);
    assertEq(actions.length, robot.MAX_ACTIONS(), 'should cap at MAX_ACTIONS');
    for (uint256 i = 0; i < actions.length; i++) {
      assertEq(actions[i].id, total - 1 - i, 'should scan from the latest proposal');
    }
  }

  function test_fuzz_checkUpkeep_stopsAfterMoreThanMaxSkipFinalProposals(uint256 finals) public {
    finals = bound(finals, 0, robot.MAX_SKIP() + 5);
    _activatable(0);
    for (uint256 i = 1; i <= finals; i++) _final(i);

    (bool needed, ) = robot.checkUpkeep('');
    assertEq(needed, finals <= robot.MAX_SKIP(), 'MAX_SKIP boundary not respected');
  }

  function test_checkUpkeep_resetsSkipCount_onNonFinalProposal() public {
    uint256 maxSkip = robot.MAX_SKIP();
    _activatable(0);
    for (uint256 i = 1; i <= maxSkip; i++) _final(i);
    gov.setProposal(maxSkip + 1, IGovernanceCore.State.Active, uint40(NOW));
    gov.setCreator(maxSkip + 1, creator);
    for (uint256 i = maxSkip + 2; i <= 2 * maxSkip + 1; i++) _final(i);

    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertTrue(needed, 'skip count not reset by the active proposal');
    assertEq(_decode(performData)[0].id, 0, 'wrong proposal');
  }

  function test_checkUpkeep_disabledFinalProposalDoesNotCountAsSkip() public {
    uint256 maxSkip = robot.MAX_SKIP();
    _activatable(0);
    for (uint256 i = 1; i <= maxSkip + 1; i++) _final(i);
    vm.prank(guardian);
    robot.disableAutomation(maxSkip + 1);

    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertTrue(needed, 'disabled final proposal counted as a skip');
    assertEq(_decode(performData)[0].id, 0, 'wrong proposal');
  }

  function test_checkUpkeep_disabledProposalDoesNotResetSkipCount() public {
    uint256 maxSkip = robot.MAX_SKIP();
    uint256 split = maxSkip / 2;
    _activatable(0);
    for (uint256 i = 1; i <= split; i++) _final(i);
    _activatable(split + 1);
    for (uint256 i = split + 2; i <= maxSkip + 2; i++) _final(i);
    vm.prank(guardian);
    robot.disableAutomation(split + 1);

    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed, 'disabled proposal reset the skip count');

    vm.prank(owner);
    robot.enableAutomation(split + 1);
    (bool neededOnceEnabled, bytes memory performData) = robot.checkUpkeep('');
    assertTrue(neededOnceEnabled, 'enabled proposal not picked');
    IGovernanceChainRobotReceiver.ActionWithId[] memory actions = _decode(performData);
    assertEq(actions.length, 2, 'enabled proposal should reset the skip count');
    assertEq(actions[0].id, split + 1, 'enabled proposal not first');
    assertEq(actions[1].id, 0, 'oldest proposal not reached');
  }

  // --- onReport ---

  function test_onReport_performsOldestFirst() public {
    _activatable(0);
    _executable(1);
    _cancellable(2);

    (, bytes memory performData) = robot.checkUpkeep('');
    vm.recordLogs();
    vm.prank(anyone);
    robot.onReport('', performData);

    Vm.Log[] memory logs = _robotLogs(vm.getRecordedLogs());
    assertEq(logs.length, 3, 'expected three ActionSucceeded');
    for (uint256 i = 0; i < 3; i++) {
      assertEq(
        logs[i].topics[0],
        IGovernanceChainRobotReceiver.ActionSucceeded.selector,
        'wrong event'
      );
      assertEq(uint256(logs[i].topics[1]), i, 'actions not performed oldest first');
    }
    assertEq(uint8(_state(0)), uint8(IGovernanceCore.State.Active), 'voting not activated');
    assertEq(uint8(_state(1)), uint8(IGovernanceCore.State.Executed), 'not executed');
    assertEq(uint8(_state(2)), uint8(IGovernanceCore.State.Cancelled), 'not cancelled');
  }

  function test_onReport_skipsDisabledProposal() public {
    _activatable(0);
    _activatable(1);
    (, bytes memory performData) = robot.checkUpkeep('');
    vm.prank(guardian);
    robot.disableAutomation(1);

    vm.prank(anyone);
    robot.onReport('', performData);
    assertEq(uint8(_state(0)), uint8(IGovernanceCore.State.Active), 'voting not activated');
    assertEq(uint8(_state(1)), uint8(IGovernanceCore.State.Created), 'disabled proposal acted on');
  }

  function test_onReport_skipsActionThatNoLongerApplies() public {
    _activatable(0);
    _executable(1);
    vm.prank(anyone);
    robot.onReport(
      '',
      _encode(
        _action(0, IGovernanceChainRobotReceiver.ProposalAction.PerformExecute),
        _action(1, IGovernanceChainRobotReceiver.ProposalAction.PerformExecute)
      )
    );
    assertEq(uint8(_state(0)), uint8(IGovernanceCore.State.Created), 'mismatched action performed');
    assertEq(uint8(_state(1)), uint8(IGovernanceCore.State.Executed), 'not executed');
  }

  function test_onReport_emitsActionFailed_andPerformsRest() public {
    _activatable(0);
    _activatable(1);
    gov.setRevertOn(0, true);
    (, bytes memory performData) = robot.checkUpkeep('');

    vm.expectEmit(address(robot));
    emit IGovernanceChainRobotReceiver.ActionFailed(
      0,
      IGovernanceChainRobotReceiver.ProposalAction.PerformActivateVoting,
      abi.encodeWithSignature('Error(string)', 'mock revert')
    );
    vm.expectEmit(address(robot));
    emit IGovernanceChainRobotReceiver.ActionSucceeded(
      1,
      IGovernanceChainRobotReceiver.ProposalAction.PerformActivateVoting
    );
    vm.prank(anyone);
    robot.onReport('', performData);

    assertEq(uint8(_state(0)), uint8(IGovernanceCore.State.Created), 'reverting proposal changed');
    assertEq(uint8(_state(1)), uint8(IGovernanceCore.State.Active), 'voting not activated');
  }

  function test_fuzz_onReport_emitsActionFailed_forEveryAction(uint8 rawAction) public {
    IGovernanceChainRobotReceiver.ProposalAction action = IGovernanceChainRobotReceiver
      .ProposalAction(bound(rawAction, 0, 2));
    if (action == IGovernanceChainRobotReceiver.ProposalAction.PerformCancel) _cancellable(0);
    else if (action == IGovernanceChainRobotReceiver.ProposalAction.PerformExecute) _executable(0);
    else _activatable(0);
    _activatable(1);
    gov.setRevertOn(0, true);

    vm.expectEmit(address(robot));
    emit IGovernanceChainRobotReceiver.ActionFailed(
      0,
      action,
      abi.encodeWithSignature('Error(string)', 'mock revert')
    );
    vm.prank(anyone);
    robot.onReport(
      '',
      _encode(
        _action(1, IGovernanceChainRobotReceiver.ProposalAction.PerformActivateVoting),
        _action(0, action)
      )
    );
  }

  function test_onReport_revertsWith_NoActionCanBePerformed_whenAllRevert() public {
    _activatable(0);
    gov.setRevertOn(0, true);
    (, bytes memory performData) = robot.checkUpkeep('');

    vm.expectRevert(IGovernanceChainRobotReceiver.NoActionCanBePerformed.selector);
    vm.prank(anyone);
    robot.onReport('', performData);
  }

  function test_onReport_revertsWith_NoActionCanBePerformed_whenStale() public {
    _activatable(0);
    (, bytes memory performData) = robot.checkUpkeep('');
    vm.prank(anyone);
    robot.onReport('', performData);

    vm.expectRevert(IGovernanceChainRobotReceiver.NoActionCanBePerformed.selector);
    vm.prank(anyone);
    robot.onReport('', performData);
  }

  function test_onReport_revertsWith_NoActionCanBePerformed_whenEmpty() public {
    vm.expectRevert(IGovernanceChainRobotReceiver.NoActionCanBePerformed.selector);
    robot.onReport('', abi.encode(new IGovernanceChainRobotReceiver.ActionWithId[](0)));
  }

  // --- helpers ---

  function _minPower() internal pure returns (uint256) {
    return uint256(MIN_PROPOSITION_POWER) * 1 ether;
  }

  function _mockGasPrice(int256 answer) internal {
    vm.mockCall(
      oracle,
      abi.encodeWithSelector(AggregatorInterface.latestAnswer.selector),
      abi.encode(answer)
    );
  }

  function _activatable(uint256 id) internal {
    gov.setProposal(id, IGovernanceCore.State.Created, uint40(NOW - VOTING_COOLDOWN - 1));
    gov.setCreator(id, creator);
  }

  function _executable(uint256 id) internal {
    gov.setProposal(id, IGovernanceCore.State.Queued, uint40(NOW - 5 days));
    gov.setCreator(id, creator);
    gov.setQueuingTime(id, uint40(NOW - QUEUE_COOLDOWN));
  }

  function _cancellable(uint256 id) internal {
    address weakCreator = makeAddr(string.concat('weak-creator-', vm.toString(id)));
    gov.setProposal(id, IGovernanceCore.State.Active, uint40(NOW - 2 days));
    gov.setCreator(id, weakCreator);
  }

  function _final(uint256 id) internal {
    gov.setProposal(id, IGovernanceCore.State.Executed, uint40(NOW - 10 days));
    gov.setCreator(id, creator);
  }

  function _state(uint256 id) internal view returns (IGovernanceCore.State) {
    return gov.getProposal(id).state;
  }

  function _toState(uint8 rawState) internal pure returns (IGovernanceCore.State) {
    return IGovernanceCore.State(bound(rawState, 0, uint8(IGovernanceCore.State.Expired)));
  }

  function _proposal(
    IGovernanceCore.State state,
    uint40 creationTime
  ) internal view returns (IGovernanceCore.Proposal memory p) {
    p.state = state;
    p.accessLevel = PayloadsControllerUtils.AccessControl.Level_1;
    p.creationTime = creationTime;
    p.creator = creator;
  }

  function _action(
    uint256 id,
    IGovernanceChainRobotReceiver.ProposalAction action
  ) internal pure returns (IGovernanceChainRobotReceiver.ActionWithId memory) {
    return IGovernanceChainRobotReceiver.ActionWithId(id, action);
  }

  function _encode(
    IGovernanceChainRobotReceiver.ActionWithId memory a
  ) internal pure returns (bytes memory) {
    IGovernanceChainRobotReceiver.ActionWithId[]
      memory actions = new IGovernanceChainRobotReceiver.ActionWithId[](1);
    actions[0] = a;
    return abi.encode(actions);
  }

  function _encode(
    IGovernanceChainRobotReceiver.ActionWithId memory a,
    IGovernanceChainRobotReceiver.ActionWithId memory b
  ) internal pure returns (bytes memory) {
    IGovernanceChainRobotReceiver.ActionWithId[]
      memory actions = new IGovernanceChainRobotReceiver.ActionWithId[](2);
    actions[0] = a;
    actions[1] = b;
    return abi.encode(actions);
  }

  function _decode(
    bytes memory performData
  ) internal pure returns (IGovernanceChainRobotReceiver.ActionWithId[] memory) {
    return abi.decode(performData, (IGovernanceChainRobotReceiver.ActionWithId[]));
  }

  function _robotLogs(Vm.Log[] memory logs) internal view returns (Vm.Log[] memory out) {
    uint256 count = 0;
    for (uint256 i = 0; i < logs.length; i++) if (logs[i].emitter == address(robot)) count++;
    out = new Vm.Log[](count);
    count = 0;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].emitter == address(robot)) out[count++] = logs[i];
    }
  }
}
