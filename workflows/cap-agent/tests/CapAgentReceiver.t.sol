// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

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

  function test_checkUpkeep_returnsFalse_whenHubHasNothingToExecute() public {
    _mockCheck(_ids(AGENT_COUNT), false, new IAgentHub.ActionData[](0));

    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertFalse(needed, 'upkeep needed when hub has nothing to execute');
    assertEq(performData.length, 0, 'performData should be empty');
  }

  function test_checkUpkeep_returnsHubActions() public {
    IAgentHub.ActionData[] memory actions = new IAgentHub.ActionData[](2);
    actions[0] = _action(0, _markets(marketA));
    actions[1] = _action(2, _markets(marketA, marketB));
    _mockCheck(_ids(AGENT_COUNT), true, actions);

    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertTrue(needed, 'upkeep should be needed');
    assertEq(performData, abi.encode(actions), 'performData mismatch');
  }

  function test_checkUpkeep_checksOnlyEnabledAgents() public {
    vm.prank(guardian);
    robot.disableAgent(1);
    _mockCheck(_two(0, 2), false, new IAgentHub.ActionData[](0));

    vm.expectCall(hub, abi.encodeCall(IAgentHub.check, (_two(0, 2))));
    robot.checkUpkeep('');
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
      if (!permissioned[i] || sender[i]) buffer[count++] = i;
    }
    uint256[] memory expected = new uint256[](count);
    for (uint256 i = 0; i < count; i++) expected[i] = buffer[i];

    assertEq(robot.executableAgents(), expected, 'unexpected executable agents');

    if (count == 0) {
      vm.expectCall(hub, abi.encodeWithSelector(IAgentHub.check.selector), 0);
    } else {
      _mockCheck(expected, false, new IAgentHub.ActionData[](0));
      vm.expectCall(hub, abi.encodeCall(IAgentHub.check, (expected)));
    }
    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed, 'upkeep needed without pending updates');
  }

  function test_checkUpkeep_capsAtMaxActions() public {
    uint256 maxActions = robot.MAX_ACTIONS();
    IAgentHub.ActionData[] memory actions = new IAgentHub.ActionData[](2);
    actions[0] = _action(0, _manyMarkets('a', maxActions - 1));
    actions[1] = _action(1, _manyMarkets('b', 5));
    _mockCheck(_ids(AGENT_COUNT), true, actions);

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
  /// one action per agent: `onReport` forwards exactly the enabled ones, or reverts if none.
  function test_fuzz_onReport_forwardsOnlyEnabledAgents(bool[3] memory enabled) public {
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
    }
    IAgentHub.ActionData[] memory forwarded = new IAgentHub.ActionData[](count);
    for (uint256 i = 0; i < count; i++) forwarded[i] = expected[i];

    assertEq(
      abi.encode(robot.enabledActions(report)),
      abi.encode(forwarded),
      'unexpected enabled actions'
    );

    if (count == 0) {
      vm.expectCall(hub, abi.encodeWithSelector(IAgentHub.execute.selector), 0);
      vm.expectRevert(ICapAgentReceiver.NoActionsToExecute.selector);
    } else {
      _mockExecute(forwarded);
      vm.expectCall(hub, abi.encodeCall(IAgentHub.execute, (forwarded)));
    }
    vm.prank(anyone);
    robot.onReport('', abi.encode(report));
  }

  function test_onReport_executesOnHub_whenAnyoneCalls() public {
    IAgentHub.ActionData[] memory actions = new IAgentHub.ActionData[](1);
    actions[0] = _action(1, _markets(marketA, marketB));
    _mockExecute(actions);

    vm.expectCall(hub, abi.encodeCall(IAgentHub.execute, (actions)));
    vm.prank(anyone);
    robot.onReport(bytes('ignored metadata'), abi.encode(actions));
  }

  function test_onReport_revertsWith_NoActionsToExecute_whenEmptyReport() public {
    vm.prank(anyone);
    vm.expectRevert(ICapAgentReceiver.NoActionsToExecute.selector);
    robot.onReport('', abi.encode(new IAgentHub.ActionData[](0)));
  }

  function test_onReport_bubblesUpHubRevert_whenNothingInjectable() public {
    IAgentHub.ActionData[] memory actions = new IAgentHub.ActionData[](1);
    actions[0] = _action(0, _markets(marketA));
    vm.mockCallRevert(
      hub,
      abi.encodeCall(IAgentHub.execute, (actions)),
      abi.encodeWithSelector(IAgentHub.NoActionCanBePerformed.selector)
    );

    vm.prank(anyone);
    vm.expectRevert(IAgentHub.NoActionCanBePerformed.selector);
    robot.onReport('', abi.encode(actions));
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

  function _mockCheck(
    uint256[] memory agentIds,
    bool shouldExecute,
    IAgentHub.ActionData[] memory actions
  ) internal {
    vm.mockCall(
      hub,
      abi.encodeCall(IAgentHub.check, (agentIds)),
      abi.encode(shouldExecute, actions)
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

  function _mockExecute(IAgentHub.ActionData[] memory actions) internal {
    vm.mockCall(hub, abi.encodeCall(IAgentHub.execute, (actions)), '');
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
