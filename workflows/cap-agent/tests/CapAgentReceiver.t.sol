// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, Vm} from 'forge-std/Test.sol';

import {Ownable} from 'openzeppelin-contracts/contracts/access/Ownable.sol';
import {IWithGuardian} from 'solidity-utils/contracts/access-control/interfaces/IWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';
import {IRescuable} from 'aave-v4/interfaces/IRescuable.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

import {ICapAgentReceiver, IAgentHub} from '../src/ICapAgentReceiver.sol';
import {CapAgentReceiverHarness} from './helpers/CapAgentReceiverHarness.sol';

contract CapAgentReceiverTest is Test {
  uint256 internal constant AGENT_COUNT = 3;

  CapAgentReceiverHarness internal robot;

  address internal owner;
  address internal guardian;
  address internal bob;
  address internal anyone;

  address internal hub;
  address internal marketA;
  address internal marketB;

  function setUp() public {
    owner = makeAddr('owner');
    guardian = makeAddr('guardian');
    bob = makeAddr('bob');
    anyone = makeAddr('anyone');

    hub = makeAddr('hub');
    marketA = makeAddr('marketA');
    marketB = makeAddr('marketB');

    // `execute` returns nothing, so Solidity checks the target has code before calling it.
    vm.etch(hub, bytes('mock'));
    vm.mockCall(
      hub,
      abi.encodeWithSelector(IAgentHub.getAgentCount.selector),
      abi.encode(AGENT_COUNT)
    );
    vm.mockCall(
      hub,
      abi.encodeWithSelector(IAgentHub.isAgentPermissioned.selector),
      abi.encode(false)
    );
    vm.mockCall(
      hub,
      abi.encodeWithSelector(IAgentHub.check.selector),
      abi.encode(false, new IAgentHub.ActionData[](0))
    );
    vm.mockCall(hub, abi.encodeWithSelector(IAgentHub.execute.selector), '');

    robot = new CapAgentReceiverHarness(hub, owner, guardian, _ids(AGENT_COUNT));
  }

  function test_constructor_setsOwnerGuardianAndHub() public view {
    assertEq(robot.owner(), owner, 'owner mismatch');
    assertEq(robot.guardian(), guardian, 'guardian mismatch');
    assertEq(address(robot.AGENT_HUB()), hub, 'agent hub mismatch');
  }

  function test_constructor_enablesInitialAgents() public {
    vm.expectEmit();
    emit ICapAgentReceiver.AgentStatusUpdated(0, true);
    vm.expectEmit();
    emit ICapAgentReceiver.AgentStatusUpdated(2, true);

    CapAgentReceiverHarness deployed = new CapAgentReceiverHarness(
      hub,
      owner,
      guardian,
      _two(0, 2)
    );

    assertTrue(deployed.isAgentEnabled(0), 'agent 0 not enabled');
    assertFalse(deployed.isAgentEnabled(1), 'agent 1 enabled');
    assertTrue(deployed.isAgentEnabled(2), 'agent 2 not enabled');
    assertEq(deployed.getEnabledAgents(), _two(0, 2), 'enabled agents mismatch');
  }

  function test_constructor_revertsWith_InvalidAgentHub() public {
    vm.expectRevert(ICapAgentReceiver.InvalidAgentHub.selector);
    new CapAgentReceiverHarness(address(0), owner, guardian, _ids(1));
  }

  function test_constructor_revertsWith_InvalidAgent_whenNotRegisteredOnHub() public {
    vm.expectRevert(abi.encodeWithSelector(ICapAgentReceiver.InvalidAgent.selector, AGENT_COUNT));
    new CapAgentReceiverHarness(hub, owner, guardian, _one(AGENT_COUNT));
  }

  function test_constructor_revertsWith_AgentStatusUnchanged_whenDuplicated() public {
    vm.expectRevert(
      abi.encodeWithSelector(ICapAgentReceiver.AgentStatusUnchanged.selector, 1, true)
    );
    new CapAgentReceiverHarness(hub, owner, guardian, _two(1, 1));
  }

  function test_MAX_ACTIONS_isTen() public view {
    assertEq(robot.MAX_ACTIONS(), 10, 'unexpected MAX_ACTIONS');
  }

  function test_MAX_REASON_LENGTH_is256() public view {
    assertEq(robot.MAX_REASON_LENGTH(), 256, 'unexpected MAX_REASON_LENGTH');
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

  function test_checkUpkeep_returnsFalse_withoutCallingHub_whenNoAgentEnabled() public {
    CapAgentReceiverHarness empty = new CapAgentReceiverHarness(
      hub,
      owner,
      guardian,
      new uint256[](0)
    );

    vm.expectCall(hub, abi.encodeWithSelector(IAgentHub.check.selector), 0);
    (bool needed, bytes memory performData) = empty.checkUpkeep('');
    assertFalse(needed, 'upkeep needed without enabled agents');
    assertEq(performData.length, 0, 'performData should be empty');
  }

  function test_checkUpkeep_returnsFalse_whenHubHasNothingToExecute() public view {
    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertFalse(needed, 'upkeep needed when hub has nothing to execute');
    assertEq(performData.length, 0, 'performData should be empty');
  }

  function test_checkUpkeep_returnsHubActions() public {
    IAgentHub.ActionData[] memory actions = new IAgentHub.ActionData[](2);
    actions[0] = _action(0, _markets(marketA));
    actions[1] = _action(2, _markets(marketA, marketB));
    _mockCheckAgent(actions[0]);
    _mockCheckAgent(actions[1]);

    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertTrue(needed, 'upkeep should be needed');
    assertEq(performData, abi.encode(actions), 'performData mismatch');
  }

  function test_checkUpkeep_checksEachEnabledAgentOnItsOwn() public {
    vm.prank(guardian);
    robot.disableAgent(1);

    vm.expectCall(hub, abi.encodeCall(IAgentHub.check, (_one(0))), 1);
    vm.expectCall(hub, abi.encodeCall(IAgentHub.check, (_one(1))), 0);
    vm.expectCall(hub, abi.encodeCall(IAgentHub.check, (_one(2))), 1);
    robot.checkUpkeep('');
  }

  /// Every combination of `check` reverting or returning an update for agents 0..2: the
  /// updates of the agents whose `check` succeeded are still returned.
  function test_fuzz_checkUpkeep_skipsAgentsWhoseCheckReverts(bool[3] memory reverts) public {
    IAgentHub.ActionData[] memory buffer = new IAgentHub.ActionData[](AGENT_COUNT);
    uint256 count = 0;
    for (uint256 i = 0; i < AGENT_COUNT; i++) {
      IAgentHub.ActionData memory action = _action(i, _markets(marketA));
      if (reverts[i]) {
        vm.mockCallRevert(hub, abi.encodeCall(IAgentHub.check, (_one(i))), 'InvalidBytesValue');
      } else {
        _mockCheckAgent(action);
        buffer[count++] = action;
      }
    }
    IAgentHub.ActionData[] memory expected = new IAgentHub.ActionData[](count);
    for (uint256 i = 0; i < count; i++) expected[i] = buffer[i];

    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertEq(needed, count > 0, 'unexpected upkeepNeeded');
    assertEq(performData, count > 0 ? abi.encode(expected) : bytes(''), 'performData mismatch');
  }

  /// Every combination of agents 0..2 permissioned or not on the hub, with or without this
  /// robot as a permissioned sender: only agents `execute` would act on reach `check`.
  function test_fuzz_checkUpkeep_skipsPermissionedAgentsWithoutRobotAsSender(
    bool[3] memory permissioned,
    bool[3] memory sender
  ) public {
    uint256[] memory buffer = new uint256[](AGENT_COUNT);
    uint256 count = 0;
    for (uint256 i = 0; i < AGENT_COUNT; i++) {
      _mockPermissioned(i, permissioned[i], sender[i]);
      bool executable = !permissioned[i] || sender[i];
      if (executable) buffer[count++] = i;
      vm.expectCall(hub, abi.encodeCall(IAgentHub.check, (_one(i))), executable ? 1 : 0);
    }
    uint256[] memory expected = new uint256[](count);
    for (uint256 i = 0; i < count; i++) expected[i] = buffer[i];

    assertEq(robot.executableAgents(), expected, 'unexpected executable agents');
    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed, 'upkeep needed without pending updates');
  }

  function test_checkUpkeep_capsAtMaxActions() public {
    uint256 maxActions = robot.MAX_ACTIONS();
    IAgentHub.ActionData[] memory actions = new IAgentHub.ActionData[](2);
    actions[0] = _action(0, _manyMarkets('a', maxActions - 1));
    actions[1] = _action(1, _manyMarkets('b', 5));
    _mockCheckAgent(actions[0]);
    _mockCheckAgent(actions[1]);

    (, bytes memory performData) = robot.checkUpkeep('');
    IAgentHub.ActionData[] memory capped = abi.decode(performData, (IAgentHub.ActionData[]));

    assertEq(capped.length, 2, 'expected both agents');
    assertEq(capped[0].markets, actions[0].markets, 'first agent markets changed');
    assertEq(capped[1].agentId, 1, 'second agent id mismatch');
    assertEq(capped[1].markets.length, 1, 'second agent should keep a single market');
    assertEq(capped[1].markets[0], actions[1].markets[0], 'second agent kept the wrong market');
  }

  /// Builds `agents` actions with a pseudo-random number of markets each and checks the cap
  /// keeps exactly the first `MAX_ACTIONS` market updates, in order, without empty actions.
  function test_fuzz_capActions_keepsFirstUpdatesInOrder(uint8 agents, uint256 seed) public view {
    agents = uint8(bound(agents, 0, 6));
    IAgentHub.ActionData[] memory actions = new IAgentHub.ActionData[](agents);
    address[] memory flat = new address[](uint256(agents) * 8);
    uint256 total = 0;
    for (uint256 i = 0; i < agents; i++) {
      uint256 count = uint256(keccak256(abi.encode(seed, i))) % 8;
      address[] memory markets = new address[](count);
      for (uint256 j = 0; j < count; j++) {
        markets[j] = address(uint160(1000 * (i + 1) + j));
        flat[total++] = markets[j];
      }
      actions[i] = _action(i, markets);
    }

    IAgentHub.ActionData[] memory capped = robot.capActions(actions);

    uint256 maxActions = robot.MAX_ACTIONS();
    uint256 kept = 0;
    for (uint256 i = 0; i < capped.length; i++) {
      assertGt(capped[i].markets.length, 0, 'empty action kept');
      if (i > 0) assertGt(capped[i].agentId, capped[i - 1].agentId, 'actions reordered');
      for (uint256 j = 0; j < capped[i].markets.length; j++) {
        assertEq(capped[i].markets[j], flat[kept++], 'market out of order');
        assertEq(
          address(uint160(1000 * (capped[i].agentId + 1) + j)),
          capped[i].markets[j],
          'market moved to another agent'
        );
      }
    }
    assertEq(kept, total < maxActions ? total : maxActions, 'unexpected number of updates kept');
  }

  /// Every combination of agents 0..2 enabled / disabled on the robot, with a report holding
  /// one action per agent: `onReport` executes exactly the enabled ones, or reverts if none.
  function test_fuzz_onReport_executesOnlyEnabledAgents(bool[3] memory enabled) public {
    IAgentHub.ActionData[] memory report = new IAgentHub.ActionData[](AGENT_COUNT);
    IAgentHub.ActionData[] memory expected = new IAgentHub.ActionData[](AGENT_COUNT);
    uint256 count = 0;
    for (uint256 i = 0; i < AGENT_COUNT; i++) {
      report[i] = _action(i, _markets(marketA));
      if (enabled[i]) {
        expected[count++] = report[i];
      } else {
        vm.prank(guardian);
        robot.disableAgent(i);
      }
      vm.expectCall(
        hub,
        abi.encodeCall(IAgentHub.execute, (_single(i, marketA))),
        enabled[i] ? 1 : 0
      );
    }
    IAgentHub.ActionData[] memory forwarded = new IAgentHub.ActionData[](count);
    for (uint256 i = 0; i < count; i++) forwarded[i] = expected[i];

    assertEq(
      abi.encode(robot.enabledActions(report)),
      abi.encode(forwarded),
      'unexpected enabled actions'
    );

    if (count == 0) vm.expectRevert(ICapAgentReceiver.NoActionsToExecute.selector);
    vm.prank(anyone);
    robot.onReport('', abi.encode(report));
  }

  function test_onReport_executesEachMarketOnItsOwn_whenAnyoneCalls() public {
    IAgentHub.ActionData[] memory actions = new IAgentHub.ActionData[](1);
    actions[0] = _action(1, _markets(marketA, marketB));

    vm.expectCall(hub, abi.encodeCall(IAgentHub.execute, (_single(1, marketA))), 1);
    vm.expectCall(hub, abi.encodeCall(IAgentHub.execute, (_single(1, marketB))), 1);
    vm.prank(anyone);
    robot.onReport(bytes('ignored metadata'), abi.encode(actions));
  }

  function test_onReport_isolatesFailingUpdate() public {
    IAgentHub.ActionData[] memory actions = new IAgentHub.ActionData[](2);
    actions[0] = _action(0, _markets(marketA));
    actions[1] = _action(1, _markets(marketB));
    bytes memory reason = abi.encodeWithSignature('Error(string)', 'no risk admin');
    _mockExecuteRevert(1, marketB, reason);

    vm.expectCall(hub, abi.encodeCall(IAgentHub.execute, (_single(0, marketA))), 1);
    vm.expectEmit(address(robot));
    emit ICapAgentReceiver.ActionFailed(1, marketB, reason);

    vm.prank(anyone);
    robot.onReport('', abi.encode(actions));
  }

  function test_onReport_revertsWith_NoActionCanBePerformed_whenEveryUpdateFails() public {
    IAgentHub.ActionData[] memory actions = new IAgentHub.ActionData[](1);
    actions[0] = _action(0, _markets(marketA, marketB));
    bytes memory reason = abi.encodeWithSelector(IAgentHub.NoActionCanBePerformed.selector);
    _mockExecuteRevert(0, marketA, reason);
    _mockExecuteRevert(0, marketB, reason);

    vm.prank(anyone);
    vm.expectRevert(IAgentHub.NoActionCanBePerformed.selector);
    robot.onReport('', abi.encode(actions));
  }

  function test_onReport_truncatesRevertReason() public {
    uint256 maxReasonLength = robot.MAX_REASON_LENGTH();
    IAgentHub.ActionData[] memory actions = new IAgentHub.ActionData[](2);
    actions[0] = _action(0, _markets(marketA));
    actions[1] = _action(1, _markets(marketB));
    bytes memory reason = new bytes(maxReasonLength * 4);
    for (uint256 i = 0; i < reason.length; i++) reason[i] = bytes1(uint8(i));
    _mockExecuteRevert(1, marketB, reason);

    vm.recordLogs();
    vm.prank(anyone);
    robot.onReport('', abi.encode(actions));

    Vm.Log[] memory logs = vm.getRecordedLogs();
    assertEq(logs.length, 1, 'expected a single ActionFailed');
    assertEq(logs[0].topics[0], ICapAgentReceiver.ActionFailed.selector, 'wrong event');
    bytes memory logged = abi.decode(logs[0].data, (bytes));
    assertEq(logged.length, maxReasonLength, 'reason not truncated');
    for (uint256 i = 0; i < logged.length; i++) {
      assertEq(logged[i], reason[i], 'truncated reason differs from the revert data');
    }
  }

  function test_onReport_revertsWith_NoActionsToExecute_whenEmptyReport() public {
    vm.prank(anyone);
    vm.expectRevert(ICapAgentReceiver.NoActionsToExecute.selector);
    robot.onReport('', abi.encode(new IAgentHub.ActionData[](0)));
  }

  function test_enableAgent() public {
    vm.prank(guardian);
    robot.disableAgent(1);

    vm.expectEmit(address(robot));
    emit ICapAgentReceiver.AgentStatusUpdated(1, true);

    vm.prank(owner);
    robot.enableAgent(1);
    assertTrue(robot.isAgentEnabled(1), 'agent not enabled');
  }

  function test_enableAgent_revertsWhenCalledByGuardian() public {
    vm.prank(guardian);
    robot.disableAgent(1);

    vm.prank(guardian);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
    robot.enableAgent(1);
  }

  function test_enableAgent_revertsWith_AgentStatusUnchanged() public {
    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(ICapAgentReceiver.AgentStatusUnchanged.selector, 0, true)
    );
    robot.enableAgent(0);
  }

  function test_enableAgent_revertsWith_InvalidAgent() public {
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(ICapAgentReceiver.InvalidAgent.selector, AGENT_COUNT));
    robot.enableAgent(AGENT_COUNT);
  }

  function test_disableAgent_byOwner() public {
    vm.expectEmit(address(robot));
    emit ICapAgentReceiver.AgentStatusUpdated(0, false);

    vm.prank(owner);
    robot.disableAgent(0);
    assertFalse(robot.isAgentEnabled(0), 'agent still enabled');
    assertEq(robot.getEnabledAgents().length, AGENT_COUNT - 1, 'agent not removed from the set');
  }

  function test_disableAgent_byGuardian() public {
    vm.prank(guardian);
    robot.disableAgent(0);
    assertFalse(robot.isAgentEnabled(0), 'agent still enabled');
  }

  function test_disableAgent_revertsWith_NotOwnerOrGuardian() public {
    vm.prank(bob);
    vm.expectRevert(
      abi.encodeWithSelector(IWithGuardian.OnlyGuardianOrOwnerInvalidCaller.selector, bob)
    );
    robot.disableAgent(0);
  }

  function test_disableAgent_revertsWith_AgentStatusUnchanged() public {
    vm.prank(guardian);
    robot.disableAgent(0);

    vm.prank(guardian);
    vm.expectRevert(
      abi.encodeWithSelector(ICapAgentReceiver.AgentStatusUnchanged.selector, 0, false)
    );
    robot.disableAgent(0);
  }

  function test_rescueGuardian_isOwner() public view {
    assertEq(robot.rescueGuardian(), owner, 'rescue guardian is not the owner');
  }

  function test_rescueToken_revertsWith_OnlyRescueGuardian() public {
    vm.prank(guardian);
    vm.expectRevert(IRescuable.OnlyRescueGuardian.selector);
    robot.rescueToken(makeAddr('token'), bob, 100);
  }

  function _mockCheckAgent(IAgentHub.ActionData memory action) internal {
    IAgentHub.ActionData[] memory actions = new IAgentHub.ActionData[](1);
    actions[0] = action;
    vm.mockCall(
      hub,
      abi.encodeCall(IAgentHub.check, (_one(action.agentId))),
      abi.encode(true, actions)
    );
  }

  function _mockPermissioned(uint256 agentId, bool permissioned, bool sender) internal {
    vm.mockCall(
      hub,
      abi.encodeCall(IAgentHub.isAgentPermissioned, (agentId)),
      abi.encode(permissioned)
    );
    vm.mockCall(
      hub,
      abi.encodeCall(IAgentHub.isPermissionedSender, (agentId, address(robot))),
      abi.encode(sender)
    );
  }

  function _mockExecuteRevert(uint256 agentId, address market, bytes memory reason) internal {
    vm.mockCallRevert(hub, abi.encodeCall(IAgentHub.execute, (_single(agentId, market))), reason);
  }

  function _single(
    uint256 agentId,
    address market
  ) internal pure returns (IAgentHub.ActionData[] memory actions) {
    actions = new IAgentHub.ActionData[](1);
    actions[0] = _action(agentId, _markets(market));
  }

  function _action(
    uint256 agentId,
    address[] memory markets
  ) internal pure returns (IAgentHub.ActionData memory) {
    return IAgentHub.ActionData({agentId: agentId, markets: markets});
  }

  function _manyMarkets(string memory prefix, uint256 count) internal returns (address[] memory m) {
    m = new address[](count);
    for (uint256 i = 0; i < count; i++) m[i] = makeAddr(string.concat(prefix, vm.toString(i)));
  }

  function _markets(address a) internal pure returns (address[] memory m) {
    m = new address[](1);
    m[0] = a;
  }

  function _markets(address a, address b) internal pure returns (address[] memory m) {
    m = new address[](2);
    m[0] = a;
    m[1] = b;
  }

  function _ids(uint256 count) internal pure returns (uint256[] memory ids) {
    ids = new uint256[](count);
    for (uint256 i = 0; i < count; i++) ids[i] = i;
  }

  function _one(uint256 a) internal pure returns (uint256[] memory ids) {
    ids = new uint256[](1);
    ids[0] = a;
  }

  function _two(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
    ids = new uint256[](2);
    ids[0] = a;
    ids[1] = b;
  }
}
