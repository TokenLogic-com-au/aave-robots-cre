// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {IPool} from 'aave-v3-origin/contracts/interfaces/IPool.sol';
import {IACLManager} from 'aave-v3-origin/contracts/interfaces/IACLManager.sol';
import {ReserveConfiguration, DataTypes} from 'aave-v3-origin/contracts/protocol/libraries/configuration/ReserveConfiguration.sol';
import {GovernanceV3Avalanche} from 'aave-address-book/GovernanceV3Avalanche.sol';
import {MiscAvalanche} from 'aave-address-book/MiscAvalanche.sol';
import {MiscPolygon} from 'aave-address-book/MiscPolygon.sol';
import {MiscOptimism} from 'aave-address-book/MiscOptimism.sol';
import {MiscArbitrum} from 'aave-address-book/MiscArbitrum.sol';
import {MiscBase} from 'aave-address-book/MiscBase.sol';
import {MiscBNB} from 'aave-address-book/MiscBNB.sol';

import {CapAgentReceiver} from '../src/CapAgentReceiver.sol';
import {ICapAgentReceiver, IAgentHub} from '../src/ICapAgentReceiver.sol';
import {DeployCapAgentReceiver} from '../scripts/DeployCapAgentReceiver.s.sol';
import {CapAgentReceiverHarness} from './helpers/CapAgentReceiverHarness.sol';
import {IAgentHubConfig, IRiskOracle, IAaveAgent, IChainlinkAgentHub} from './helpers/RiskAgentsInterfaces.sol';

/// @dev Grants what governance must grant for injections and publishes Risk Oracle cap updates.
abstract contract CapAgentForkBase is Test {
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

  // Agent ids registered on every covered hub (see the deploy script).
  uint256 internal constant SUPPLY_CAP_AGENT = 0;
  uint256 internal constant BORROW_CAP_AGENT = 1;

  // Published caps are 1% above the current ones, well inside the agents' default range.
  uint256 internal constant CAP_INCREASE_BPS = 1_00;
  uint256 internal constant BPS = 100_00;

  address internal anyone = makeAddr('fork-anyone');
  address internal publisher = makeAddr('fork-risk-oracle-publisher');

  struct CapUpdate {
    uint256 agentId;
    address market;
    uint256 newCap;
    uint256 updateId;
  }

  /// Enables the agent on the hub and makes it a risk admin, so its config engine call can set caps.
  function _allowInjection(IAgentHubConfig hub, uint256 agentId, address aclAdmin) internal {
    address agent = hub.getAgentAddress(agentId);

    vm.prank(hub.getAgentAdmin(agentId));
    hub.setAgentEnabled(agentId, true);

    IACLManager acl = IACLManager(_pool(hub, agentId).ADDRESSES_PROVIDER().getACLManager());
    if (!acl.isRiskAdmin(agent)) {
      vm.prank(aclAdmin);
      acl.addRiskAdmin(agent);
    }
  }

  /// Publishes a cap update for the first allowed market with a cap, past the minimum delay.
  function _publishCapUpdate(
    IAgentHubConfig hub,
    uint256 agentId
  ) internal returns (CapUpdate memory update) {
    require(!hub.isMarketsFromAgentEnabled(agentId), 'agent reads markets from the agent');

    address[] memory markets = hub.getAllowedMarkets(agentId);
    uint256 minimumDelay = hub.getMinimumDelay(agentId);
    uint256 cap = 0;
    for (uint256 i = 0; i < markets.length && cap == 0; i++) {
      uint256 lastInjected = hub.getLastInjectedUpdate(agentId, markets[i]).timestamp;
      if (lastInjected != 0 && block.timestamp - lastInjected < minimumDelay) continue;
      cap = _cap(hub, agentId, markets[i]);
      update.market = markets[i];
    }
    require(cap != 0, 'no allowed market with a cap the agent can update');

    uint256 increase = (cap * CAP_INCREASE_BPS) / BPS;
    update.agentId = agentId;
    update.newCap = cap + (increase == 0 ? 1 : increase);

    IRiskOracle oracle = IRiskOracle(hub.getRiskOracle(agentId));
    if (!oracle.isAuthorized(publisher)) {
      vm.prank(oracle.owner());
      oracle.addAuthorizedSender(publisher);
    }

    string memory updateType = hub.getUpdateType(agentId);
    vm.prank(publisher);
    oracle.publishRiskParameterUpdate(
      'cap-agent-fork-test',
      abi.encode(update.newCap),
      updateType,
      update.market,
      ''
    );
    update.updateId = oracle.updateCounter();
  }

  function _assertInjected(IAgentHubConfig hub, CapUpdate memory update) internal view {
    assertEq(_cap(hub, update.agentId, update.market), update.newCap, 'cap not updated');
    assertEq(
      hub.getLastInjectedUpdate(update.agentId, update.market).id,
      update.updateId,
      'update not recorded as injected'
    );
  }

  function _assertActions(
    bytes memory performData,
    CapUpdate memory first,
    CapUpdate memory second
  ) internal pure {
    IAgentHub.ActionData[] memory actions = abi.decode(performData, (IAgentHub.ActionData[]));
    assertEq(actions.length, 2, 'expected one action per agent');
    assertEq(actions[0].agentId, first.agentId, 'unexpected first agent');
    assertEq(actions[0].markets.length, 1, 'unexpected markets for the first agent');
    assertEq(actions[0].markets[0], first.market, 'unexpected market for the first agent');
    assertEq(actions[1].agentId, second.agentId, 'unexpected second agent');
    assertEq(actions[1].markets.length, 1, 'unexpected markets for the second agent');
    assertEq(actions[1].markets[0], second.market, 'unexpected market for the second agent');
  }

  function _cap(
    IAgentHubConfig hub,
    uint256 agentId,
    address market
  ) internal view returns (uint256) {
    DataTypes.ReserveConfigurationMap memory config = _pool(hub, agentId).getConfiguration(market);
    return agentId == SUPPLY_CAP_AGENT ? config.getSupplyCap() : config.getBorrowCap();
  }

  function _pool(IAgentHubConfig hub, uint256 agentId) internal view returns (IPool) {
    return IAaveAgent(hub.getAgentAddress(agentId)).POOL();
  }
}

contract CapAgentReceiverForkTest is CapAgentForkBase {
  CapAgentReceiverHarness internal robot;
  address internal owner = makeAddr('fork-owner');
  address internal guardian = makeAddr('fork-guardian');

  IAgentHubConfig internal hub = IAgentHubConfig(MiscAvalanche.AGENT_HUB);

  function setUp() public {
    vm.createSelectFork('avalanche');
    robot = new CapAgentReceiverHarness(address(hub), owner, guardian, _agentIds());
  }

  function test_fork_readPath_matchesLegacyAutomation() public view {
    assertEq(
      IChainlinkAgentHub(MiscAvalanche.AGENT_HUB_AUTOMATION).AGENT_HUB(),
      address(hub),
      'legacy automation runs on another hub'
    );
    assertGe(hub.getAgentCount(), _agentIds().length, 'hub has fewer agents than enabled');

    (bool hubNeeded, ) = hub.check(_agentIds());
    (bool needed, ) = robot.checkUpkeep('');
    assertEq(needed, hubNeeded, 'checkUpkeep disagrees with the hub');
  }

  function test_fork_onReport_revertsNoActionCanBePerformed_whenNoUpdateForMarket() public {
    address[] memory markets = new address[](1);
    markets[0] = makeAddr('market-without-updates');
    IAgentHub.ActionData[] memory actions = new IAgentHub.ActionData[](1);
    actions[0] = IAgentHub.ActionData({agentId: SUPPLY_CAP_AGENT, markets: markets});

    vm.prank(anyone);
    vm.expectRevert(IAgentHub.NoActionCanBePerformed.selector);
    robot.onReport('', abi.encode(actions));
  }

  /// Publishes a supply and a borrow cap update and checks the robot injects both in one
  /// report on the live hub.
  function test_fork_onReport_injectsSupplyAndBorrowCaps() public {
    _allowInjection(hub, SUPPLY_CAP_AGENT, GovernanceV3Avalanche.EXECUTOR_LVL_1);
    _allowInjection(hub, BORROW_CAP_AGENT, GovernanceV3Avalanche.EXECUTOR_LVL_1);
    CapUpdate memory supply = _publishCapUpdate(hub, SUPPLY_CAP_AGENT);
    CapUpdate memory borrow = _publishCapUpdate(hub, BORROW_CAP_AGENT);

    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertTrue(needed, 'checkUpkeep should flag the published updates');
    _assertActions(performData, supply, borrow);

    vm.prank(anyone);
    robot.onReport('', performData);

    _assertInjected(hub, supply);
    _assertInjected(hub, borrow);
    (needed, ) = robot.checkUpkeep('');
    assertFalse(needed, 'upkeep still needed after injection');
  }

  function test_fork_onReport_skipsDisabledAgent() public {
    _allowInjection(hub, SUPPLY_CAP_AGENT, GovernanceV3Avalanche.EXECUTOR_LVL_1);
    _publishCapUpdate(hub, SUPPLY_CAP_AGENT);
    (, bytes memory performData) = robot.checkUpkeep('');

    vm.prank(guardian);
    robot.disableAgent(SUPPLY_CAP_AGENT);

    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed, 'upkeep needed for an agent disabled on the robot');
    vm.prank(anyone);
    vm.expectRevert(ICapAgentReceiver.NoActionsToExecute.selector);
    robot.onReport('', performData);
  }

  /// A permissioned agent only injects for its permissioned senders, so governance must add
  /// the receiver as one; until then `checkUpkeep` skips it.
  function test_fork_permissionedAgent_needsReceiverAsSender() public {
    _allowInjection(hub, SUPPLY_CAP_AGENT, GovernanceV3Avalanche.EXECUTOR_LVL_1);
    CapUpdate memory supply = _publishCapUpdate(hub, SUPPLY_CAP_AGENT);
    (, bytes memory performData) = robot.checkUpkeep('');
    address admin = hub.getAgentAdmin(SUPPLY_CAP_AGENT);
    vm.prank(admin);
    hub.setAgentAsPermissioned(SUPPLY_CAP_AGENT, true);

    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed, 'upkeep needed for a permissioned agent without the robot as sender');
    vm.prank(anyone);
    vm.expectRevert(IAgentHub.NoActionCanBePerformed.selector);
    robot.onReport('', performData);

    vm.prank(admin);
    hub.addPermissionedSender(SUPPLY_CAP_AGENT, address(robot));

    bytes memory newPerformData;
    (needed, newPerformData) = robot.checkUpkeep('');
    assertTrue(needed, 'upkeep not needed once the robot is a permissioned sender');
    assertEq(newPerformData, performData, 'unexpected performData');
    vm.prank(anyone);
    robot.onReport('', newPerformData);
    _assertInjected(hub, supply);
  }

  function _agentIds() internal pure returns (uint256[] memory ids) {
    ids = new uint256[](3);
    ids[0] = 0;
    ids[1] = 1;
    ids[2] = 2;
  }
}

/// Runs the deploy script on every covered chain and injects a real supply and borrow cap
/// update through the deployed receiver.
contract CapAgentDeployScriptForkTest is CapAgentForkBase {
  function test_fork_avalanche_deployScriptInjects() public {
    _deployAndInject('avalanche', MiscAvalanche.AGENT_HUB_AUTOMATION);
  }

  function test_fork_polygon_deployScriptInjects() public {
    _deployAndInject('polygon', MiscPolygon.AGENT_HUB_AUTOMATION);
  }

  function test_fork_optimism_deployScriptInjects() public {
    _deployAndInject('optimism', MiscOptimism.AGENT_HUB_AUTOMATION);
  }

  function test_fork_arbitrum_deployScriptInjects() public {
    _deployAndInject('arbitrum', MiscArbitrum.AGENT_HUB_AUTOMATION);
  }

  function test_fork_base_deployScriptInjects() public {
    _deployAndInject('base', MiscBase.AGENT_HUB_AUTOMATION);
  }

  function test_fork_bnb_deployScriptInjects() public {
    _deployAndInject('bnb', MiscBNB.AGENT_HUB_AUTOMATION);
  }

  function _deployAndInject(string memory chain, address legacyAutomation) internal {
    vm.createSelectFork(chain);
    DeployCapAgentReceiver script = new DeployCapAgentReceiver();
    DeployCapAgentReceiver.DeployConfig memory config = script.getDeployConfig(block.chainid);
    CapAgentReceiver receiver = CapAgentReceiver(script.run());
    IAgentHubConfig hub = IAgentHubConfig(config.agentHub);

    assertEq(address(receiver.AGENT_HUB()), config.agentHub, 'receiver points to another hub');
    assertEq(
      IChainlinkAgentHub(legacyAutomation).AGENT_HUB(),
      config.agentHub,
      'legacy automation runs on another hub'
    );
    assertEq(receiver.owner(), config.owner, 'unexpected owner');
    assertEq(receiver.guardian(), config.guardian, 'unexpected guardian');
    assertEq(receiver.getEnabledAgents(), config.agentIds, 'unexpected enabled agents');
    assertEq(hub.getAgentCount(), config.agentIds.length, 'hub agents not all covered');

    _allowInjection(hub, SUPPLY_CAP_AGENT, config.owner);
    _allowInjection(hub, BORROW_CAP_AGENT, config.owner);
    CapUpdate memory supply = _publishCapUpdate(hub, SUPPLY_CAP_AGENT);
    CapUpdate memory borrow = _publishCapUpdate(hub, BORROW_CAP_AGENT);

    (bool needed, bytes memory performData) = receiver.checkUpkeep('');
    assertTrue(needed, string.concat(chain, ': checkUpkeep should flag the published updates'));
    _assertActions(performData, supply, borrow);

    vm.prank(anyone);
    receiver.onReport('', performData);

    _assertInjected(hub, supply);
    _assertInjected(hub, borrow);
  }
}
