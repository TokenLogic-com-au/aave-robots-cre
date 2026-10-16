// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPool} from 'aave-v3-origin/contracts/interfaces/IPool.sol';

import {IAgentHub} from '../../src/ICapAgentReceiver.sol';

/// @dev `AgentHub` configuration methods used by the fork tests. Subset of
/// https://github.com/ChaosLabsInc/chaos-agents/blob/main/src/interfaces/IAgentConfigurator.sol
interface IAgentHubConfig is IAgentHub {
  struct LastInjectedUpdate {
    uint48 timestamp;
    uint208 id;
  }

  function setAgentEnabled(uint256 agentId, bool enable) external;

  function setAgentAsPermissioned(uint256 agentId, bool isAgentPermissioned) external;

  function addPermissionedSender(uint256 agentId, address sender) external;

  function getAgentAdmin(uint256 agentId) external view returns (address);

  function getAgentAddress(uint256 agentId) external view returns (address);

  function getRiskOracle(uint256 agentId) external view returns (address);

  function getUpdateType(uint256 agentId) external view returns (string memory);

  function getAllowedMarkets(uint256 agentId) external view returns (address[] memory);

  function isMarketsFromAgentEnabled(uint256 agentId) external view returns (bool);

  function getMinimumDelay(uint256 agentId) external view returns (uint256);

  function getLastInjectedUpdate(
    uint256 agentId,
    address market
  ) external view returns (LastInjectedUpdate memory);
}

/// @dev Subset of https://github.com/ChaosLabsInc/chaos-agents/blob/main/src/contracts/dependencies/IRiskOracle.sol
/// plus the `Ownable` owner.
interface IRiskOracle {
  function owner() external view returns (address);

  function addAuthorizedSender(address sender) external;

  function isAuthorized(address sender) external view returns (bool);

  function updateCounter() external view returns (uint256);

  function publishRiskParameterUpdate(
    string memory referenceId,
    bytes memory newValue,
    string memory updateType,
    address market,
    bytes memory additionalData
  ) external;
}

/// @dev Aave agents (`BaseAaveAgent` in https://github.com/aave-dao/aave-risk-agents) expose
/// the Pool they update.
interface IAaveAgent {
  function POOL() external view returns (IPool);
}

/// @dev BGD's `ChainlinkAgentHub`, the Chainlink Automation wrapper this robot replaces.
/// https://github.com/ChaosLabsInc/chaos-agents/blob/main/src/contracts/automation/ChainlinkAgentHub.sol
interface IChainlinkAgentHub {
  function AGENT_HUB() external view returns (address);
}
