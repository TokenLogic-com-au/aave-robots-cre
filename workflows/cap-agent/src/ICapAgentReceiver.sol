// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

/// @notice `AgentHub` methods used by the robot.
/// @dev Subset of https://github.com/ChaosLabsInc/chaos-agents/blob/main/src/interfaces/IAgentHub.sol
/// and its parent `IAgentConfigurator`.
interface IAgentHub {
  /// @notice Thrown by `execute` when no update could be injected.
  error NoActionCanBePerformed();

  struct ActionData {
    uint256 agentId;
    address[] markets;
  }

  function check(
    uint256[] memory agentIds
  ) external view returns (bool shouldExecute, ActionData[] memory actions);

  function execute(ActionData[] memory actions) external;

  function getAgentCount() external view returns (uint256);
}

/// @title ICapAgentReceiver
/// @notice Robot that injects Risk Oracle updates through an Aave `AgentHub` (supply / borrow
/// caps, rate strategies) for the agents it is enabled for.
/// @dev `checkData` is unused (the hub and the agents are set on the contract); `performData`
/// and the `report` are `abi.encode(IAgentHub.ActionData[])`.
interface ICapAgentReceiver is IAaveCREReceiver {
  /// @notice Emitted when an agent is added to or removed from the automation allowlist.
  /// @param agentId The agent updated.
  /// @param enabled Whether the agent is now enabled for automation.
  event AgentStatusUpdated(uint256 indexed agentId, bool enabled);

  /// @notice Thrown when `onReport` runs with no action for an enabled agent.
  error NoActionsToExecute();

  /// @notice Thrown when the AgentHub passed to the constructor is the zero address.
  error InvalidAgentHub();

  /// @notice Thrown when enabling an agent not registered on the AgentHub.
  /// @param agentId The agent requested.
  error InvalidAgent(uint256 agentId);

  /// @notice Thrown when enabling / disabling an agent that already has that status.
  /// @param agentId The agent updated.
  /// @param enabled The status that was requested.
  error AgentStatusUnchanged(uint256 agentId, bool enabled);

  /// @notice The AgentHub this robot executes on.
  function AGENT_HUB() external view returns (IAgentHub);

  /// @notice Max market updates returned by a single `checkUpkeep` (the rest are picked up
  /// next tick).
  function MAX_ACTIONS() external pure returns (uint256);

  /// @notice Add an agent to the automation allowlist. Owner-only.
  /// @param agentId The agent to enable. Must be registered on the hub and not already enabled.
  function enableAgent(uint256 agentId) external;

  /// @notice Remove an agent from the automation allowlist. Owner or guardian.
  /// @param agentId The agent to disable. Must be currently enabled.
  function disableAgent(uint256 agentId) external;

  /// @notice Whether an agent is enabled for automation on this robot. Independent of the
  /// hub's own `isAgentEnabled`, which must also be true for updates to be injected.
  /// @param agentId The agent to query.
  function isAgentEnabled(uint256 agentId) external view returns (bool);

  /// @notice The agents enabled for automation on this robot.
  function getEnabledAgents() external view returns (uint256[] memory);
}
