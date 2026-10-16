// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from 'forge-std/Script.sol';

import {ChainIds} from 'solidity-utils/contracts/utils/ChainHelpers.sol';
import {GovernanceV3Avalanche} from 'aave-address-book/GovernanceV3Avalanche.sol';
import {GovernanceV3Polygon} from 'aave-address-book/GovernanceV3Polygon.sol';
import {GovernanceV3Optimism} from 'aave-address-book/GovernanceV3Optimism.sol';
import {GovernanceV3Arbitrum} from 'aave-address-book/GovernanceV3Arbitrum.sol';
import {GovernanceV3Base} from 'aave-address-book/GovernanceV3Base.sol';
import {GovernanceV3BNB} from 'aave-address-book/GovernanceV3BNB.sol';
import {MiscAvalanche} from 'aave-address-book/MiscAvalanche.sol';
import {MiscPolygon} from 'aave-address-book/MiscPolygon.sol';
import {MiscOptimism} from 'aave-address-book/MiscOptimism.sol';
import {MiscArbitrum} from 'aave-address-book/MiscArbitrum.sol';
import {MiscBase} from 'aave-address-book/MiscBase.sol';
import {MiscBNB} from 'aave-address-book/MiscBNB.sol';

import {CapAgentReceiver} from '../src/CapAgentReceiver.sol';

// make deploy-cap-agent env=<Avalanche|Polygon|Optimism|Arbitrum|Base|BNB> [dry=1]
contract DeployCapAgentReceiver is Script {
  struct DeployConfig {
    address agentHub;
    address owner;
    address guardian;
    uint256[] agentIds;
  }

  function run() external returns (address) {
    DeployConfig memory config = getDeployConfig(block.chainid);
    require(config.agentHub.code.length > 0, 'agent hub not deployed on this chain');

    vm.startBroadcast();
    CapAgentReceiver receiver = new CapAgentReceiver(
      config.agentHub,
      config.owner,
      config.guardian,
      config.agentIds
    );
    vm.stopBroadcast();

    console.log('CapAgentReceiver deployed at:', address(receiver));
    console.log('AgentHub:', config.agentHub);
    console.log('Owner:', config.owner);
    console.log('Guardian:', config.guardian);
    for (uint256 i = 0; i < config.agentIds.length; i++) {
      console.log('Enabled agent:', config.agentIds[i]);
    }
    return address(receiver);
  }

  /// @dev The chains where BGD's `ChainlinkAgentHub` runs, with the agent ids its upkeep
  /// checks: supply and borrow caps everywhere, plus rate strategies on Avalanche, Arbitrum
  /// and Base. Owner / guardian are the chain's governance executor and guardian.
  function getDeployConfig(uint256 chainId) public pure returns (DeployConfig memory) {
    if (chainId == ChainIds.AVALANCHE)
      return
        DeployConfig(
          MiscAvalanche.AGENT_HUB,
          GovernanceV3Avalanche.EXECUTOR_LVL_1,
          GovernanceV3Avalanche.GOVERNANCE_GUARDIAN,
          _ids(3)
        );
    if (chainId == ChainIds.POLYGON)
      return
        DeployConfig(
          MiscPolygon.AGENT_HUB,
          GovernanceV3Polygon.EXECUTOR_LVL_1,
          GovernanceV3Polygon.GOVERNANCE_GUARDIAN,
          _ids(2)
        );
    if (chainId == ChainIds.OPTIMISM)
      return
        DeployConfig(
          MiscOptimism.AGENT_HUB,
          GovernanceV3Optimism.EXECUTOR_LVL_1,
          GovernanceV3Optimism.GOVERNANCE_GUARDIAN,
          _ids(2)
        );
    if (chainId == ChainIds.ARBITRUM)
      return
        DeployConfig(
          MiscArbitrum.AGENT_HUB,
          GovernanceV3Arbitrum.EXECUTOR_LVL_1,
          GovernanceV3Arbitrum.GOVERNANCE_GUARDIAN,
          _ids(3)
        );
    if (chainId == ChainIds.BASE)
      return
        DeployConfig(
          MiscBase.AGENT_HUB,
          GovernanceV3Base.EXECUTOR_LVL_1,
          GovernanceV3Base.GOVERNANCE_GUARDIAN,
          _ids(3)
        );
    if (chainId == ChainIds.BNB)
      return
        DeployConfig(
          MiscBNB.AGENT_HUB,
          GovernanceV3BNB.EXECUTOR_LVL_1,
          GovernanceV3BNB.GOVERNANCE_GUARDIAN,
          _ids(2)
        );
    revert('unsupported chain');
  }

  /// @dev Agent ids `0..count-1`.
  function _ids(uint256 count) internal pure returns (uint256[] memory ids) {
    ids = new uint256[](count);
    for (uint256 i = 0; i < count; i++) ids[i] = i;
  }
}
