// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';

import {ChainIds} from 'solidity-utils/contracts/utils/ChainHelpers.sol';
import {MiscAvalanche} from 'aave-address-book/MiscAvalanche.sol';
import {MiscPolygon} from 'aave-address-book/MiscPolygon.sol';
import {MiscOptimism} from 'aave-address-book/MiscOptimism.sol';
import {MiscArbitrum} from 'aave-address-book/MiscArbitrum.sol';
import {MiscBase} from 'aave-address-book/MiscBase.sol';
import {MiscBNB} from 'aave-address-book/MiscBNB.sol';

import {GovernanceOwners} from '../../shared/scripts/GovernanceOwners.sol';
import {CapAgentReceiver} from '../src/CapAgentReceiver.sol';

// make deploy-cap-agent env=<Avalanche|Polygon|Optimism|Arbitrum|Base|BNB> [dry=1]
contract DeployCapAgentReceiver is Script {
  // Agents 0 (supply cap) and 1 (borrow cap), registered on every covered hub.
  uint256 internal constant CAP_AGENTS = 2;
  // Plus agent 2 (rate strategy), registered on Avalanche, Arbitrum and Base.
  uint256 internal constant CAP_AND_RATE_AGENTS = 3;

  struct DeployConfig {
    address agentHub;
    uint256[] agentIds;
  }

  function run() external returns (address) {
    DeployConfig memory config = getDeployConfig(block.chainid);
    require(config.agentHub.code.length > 0, 'agent hub not deployed on this chain');
    (address owner, address guardian) = GovernanceOwners.get(block.chainid);

    vm.startBroadcast();
    CapAgentReceiver receiver = new CapAgentReceiver(
      config.agentHub,
      owner,
      guardian,
      config.agentIds
    );
    vm.stopBroadcast();

    return address(receiver);
  }

  function getDeployConfig(uint256 chainId) public pure returns (DeployConfig memory) {
    if (chainId == ChainIds.AVALANCHE) {
      return DeployConfig(MiscAvalanche.AGENT_HUB, _ids(CAP_AND_RATE_AGENTS));
    }
    if (chainId == ChainIds.POLYGON) {
      return DeployConfig(MiscPolygon.AGENT_HUB, _ids(CAP_AGENTS));
    }
    if (chainId == ChainIds.OPTIMISM) {
      return DeployConfig(MiscOptimism.AGENT_HUB, _ids(CAP_AGENTS));
    }
    if (chainId == ChainIds.ARBITRUM) {
      return DeployConfig(MiscArbitrum.AGENT_HUB, _ids(CAP_AND_RATE_AGENTS));
    }
    if (chainId == ChainIds.BASE) {
      return DeployConfig(MiscBase.AGENT_HUB, _ids(CAP_AND_RATE_AGENTS));
    }
    if (chainId == ChainIds.BNB) {
      return DeployConfig(MiscBNB.AGENT_HUB, _ids(CAP_AGENTS));
    }
    revert('unsupported chain');
  }

  /// @dev Agent ids `0..count-1`.
  function _ids(uint256 count) internal pure returns (uint256[] memory ids) {
    ids = new uint256[](count);
    for (uint256 i = 0; i < count; i++) ids[i] = i;
  }
}
