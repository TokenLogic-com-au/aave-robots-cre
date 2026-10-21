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

  function isAgentPermissioned(uint256 agentId) external view returns (bool);

  function isPermissionedSender(uint256 agentId, address sender) external view returns (bool);
}

/// @title ICapAgentReceiver
/// @author Aave Labs
/// @notice Robot that injects Risk Oracle updates (caps, rate strategies) through an Aave
/// `AgentHub` for the agents it is enabled for.
/// @dev `checkData` is unused; `performData` and the `report` are
/// `abi.encode(IAgentHub.ActionData[])`.
interface ICapAgentReceiver is IAaveCREReceiver {
  /// @notice Emitted when an agent is added to or removed from the automation allowlist.
  /// @param agentId The agent updated.
  /// @param enabled Whether the agent is now enabled for automation.
  event AgentStatusUpdated(uint256 indexed agentId, bool enabled);

  /// @notice Emitted by `onReport` for each market update whose `execute` call reverted.
  /// @param agentId The agent of the update.
  /// @param market The market of the update.
  /// @param reason The revert data, truncated to `MAX_REASON_LENGTH` bytes.
  event ActionFailed(uint256 indexed agentId, address indexed market, bytes reason);

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

  /// @notice Max market updates returned by a single `checkUpkeep`.
  function MAX_ACTIONS() external pure returns (uint256);

  /// @notice Max bytes of revert data kept in `ActionFailed`.
  function MAX_REASON_LENGTH() external pure returns (uint256);

  /// @notice Add an agent to the automation allowlist. Owner-only.
  /// @param agentId The agent to enable. Must be registered on the hub and not already enabled.
  function enableAgent(uint256 agentId) external;

  /// @notice Remove an agent from the automation allowlist. Owner or guardian.
  /// @param agentId The agent to disable. Must be currently enabled.
  function disableAgent(uint256 agentId) external;

  /// @notice Whether an agent is enabled on this robot (independent of the hub's own
  /// `isAgentEnabled`).
  /// @param agentId The agent to query.
  function isAgentEnabled(uint256 agentId) external view returns (bool);

  /// @notice The agents enabled for automation on this robot.
  function getEnabledAgents() external view returns (uint256[] memory);
}
