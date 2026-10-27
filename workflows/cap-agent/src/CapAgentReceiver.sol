// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EnumerableSet} from 'openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol';

import {WorkflowsBase} from 'aave-cre/WorkflowsBase.sol';
import {ICapAgentReceiver, IAgentHub} from './ICapAgentReceiver.sol';

/// @title CapAgentReceiver
/// @author Aave Labs
/// @notice Receives reports from the CRE workflow and injects pending Risk Oracle updates
/// through the AgentHub. Native CRE port of BGD's `ChainlinkAgentHub`.
/// @dev `onReport` is permissionless: `AgentHub.execute` re-validates every update.
contract CapAgentReceiver is WorkflowsBase, ICapAgentReceiver {
  using EnumerableSet for EnumerableSet.UintSet;

  /// @inheritdoc ICapAgentReceiver
  uint256 public constant override MAX_ACTIONS = 10;

  /// @inheritdoc ICapAgentReceiver
  uint256 public constant override MAX_REASON_LENGTH = 256;

  /// @inheritdoc ICapAgentReceiver
  IAgentHub public immutable override AGENT_HUB;

  EnumerableSet.UintSet internal _enabledAgents;

  /// @param agentHub_ The AgentHub to execute on.
  /// @param initialOwner_ The address of the initial owner.
  /// @param initialGuardian_ The address of the initial guardian.
  /// @param initialAgentIds_ The agents enabled for automation at deployment.
  constructor(
    address agentHub_,
    address initialOwner_,
    address initialGuardian_,
    uint256[] memory initialAgentIds_
  ) WorkflowsBase(initialOwner_, initialGuardian_) {
    require(agentHub_ != address(0), InvalidAgentHub());

    AGENT_HUB = IAgentHub(agentHub_);
    for (uint256 i = 0; i < initialAgentIds_.length; i++) {
      _enableAgent(initialAgentIds_[i]);
    }
  }

  /// @inheritdoc ICapAgentReceiver
  function enableAgent(uint256 agentId) external onlyOwner {
    _enableAgent(agentId);
  }

  /// @inheritdoc ICapAgentReceiver
  function disableAgent(uint256 agentId) external onlyOwnerOrGuardian {
    require(_enabledAgents.remove(agentId), AgentStatusUnchanged(agentId, false));

    emit AgentStatusUpdated(agentId, false);
  }

  /// @inheritdoc ICapAgentReceiver
  function isAgentEnabled(uint256 agentId) external view returns (bool) {
    return _enabledAgents.contains(agentId);
  }

  /// @inheritdoc ICapAgentReceiver
  function getEnabledAgents() external view returns (uint256[] memory) {
    return _enabledAgents.values();
  }

  /// @dev Drops actions for agents not enabled on this robot and executes each market update
  /// in its own `execute` call, so one failing injection doesn't block the others. Reverts
  /// `NoActionCanBePerformed` if none succeeded, so a stale report fails `estimateGas`.
  function _onReport(bytes calldata /* metadata */, bytes calldata report) internal override {
    IAgentHub.ActionData[] memory actions = _enabledActions(
      abi.decode(report, (IAgentHub.ActionData[]))
    );
    require(actions.length > 0, NoActionsToExecute());

    bool executed = false;
    for (uint256 i = 0; i < actions.length; i++) {
      for (uint256 j = 0; j < actions[i].markets.length; j++) {
        (bool success, bytes memory reason) = _execute(actions[i].agentId, actions[i].markets[j]);
        if (success) {
          executed = true;
        } else {
          emit ActionFailed(actions[i].agentId, actions[i].markets[j], reason);
        }
      }
    }
    require(executed, IAgentHub.NoActionCanBePerformed());
  }

  function _checkUpkeep(
    bytes calldata /* checkData */
  ) internal view override returns (bool, bytes memory) {
    IAgentHub.ActionData[] memory actions = _checkAgents(_executableAgents());
    if (actions.length == 0) return (false, '');

    return (true, abi.encode(_capActions(actions)));
  }

  /// @dev Keeps the actions for agents enabled on this robot.
  function _enabledActions(
    IAgentHub.ActionData[] memory actions
  ) internal view returns (IAgentHub.ActionData[] memory) {
    IAgentHub.ActionData[] memory buffer = new IAgentHub.ActionData[](actions.length);
    uint256 count = 0;

    for (uint256 i = 0; i < actions.length; i++) {
      if (_enabledAgents.contains(actions[i].agentId)) buffer[count++] = actions[i];
    }

    return _shrink(buffer, count);
  }

  /// @dev `AGENT_HUB.execute` for a single market update, copying at most `MAX_REASON_LENGTH`
  /// bytes of revert data.
  function _execute(
    uint256 agentId,
    address market
  ) internal returns (bool success, bytes memory reason) {
    IAgentHub.ActionData[] memory action = new IAgentHub.ActionData[](1);
    action[0].agentId = agentId;
    action[0].markets = new address[](1);
    action[0].markets[0] = market;
    bytes memory data = abi.encodeCall(IAgentHub.execute, (action));
    address hub = address(AGENT_HUB);
    uint256 length;

    assembly ('memory-safe') {
      success := call(gas(), hub, 0, add(data, 0x20), mload(data), 0, 0)
      length := returndatasize()
    }
    if (success) return (true, '');

    if (length > MAX_REASON_LENGTH) length = MAX_REASON_LENGTH;
    reason = new bytes(length);
    assembly ('memory-safe') {
      returndatacopy(add(reason, 0x20), 0, length)
    }
  }

  /// @dev Enabled agents `execute` would act on for this contract: a permissioned agent only
  /// injects for its permissioned senders, and would otherwise fill `MAX_ACTIONS` with no-ops.
  function _executableAgents() internal view returns (uint256[] memory) {
    uint256[] memory enabled = _enabledAgents.values();
    uint256[] memory buffer = new uint256[](enabled.length);
    uint256 count = 0;

    for (uint256 i = 0; i < enabled.length; i++) {
      if (
        !AGENT_HUB.isAgentPermissioned(enabled[i]) ||
        AGENT_HUB.isPermissionedSender(enabled[i], address(this))
      ) buffer[count++] = enabled[i];
    }

    uint256[] memory agentIds = new uint256[](count);
    for (uint256 i = 0; i < count; i++) agentIds[i] = buffer[i];
    return agentIds;
  }

  /// @dev Checks each agent on its own, so an update that makes the hub's `check` revert
  /// (e.g. a malformed value failing the agent's validation) only skips that agent.
  function _checkAgents(
    uint256[] memory agentIds
  ) internal view returns (IAgentHub.ActionData[] memory) {
    IAgentHub.ActionData[] memory buffer = new IAgentHub.ActionData[](agentIds.length);
    uint256[] memory agentId = new uint256[](1);
    uint256 count = 0;

    for (uint256 i = 0; i < agentIds.length; i++) {
      agentId[0] = agentIds[i];
      try AGENT_HUB.check(agentId) returns (
        bool shouldExecute,
        IAgentHub.ActionData[] memory actions
      ) {
        // `check` returns at most one action per requested agent.
        if (shouldExecute && actions.length > 0) buffer[count++] = actions[0];
      } catch {}
    }

    return _shrink(buffer, count);
  }

  /// @dev Keeps the first `MAX_ACTIONS` market updates, in order (the hub's `maxBatchSize` is
  /// unset, so `check` returns every pending update).
  function _capActions(
    IAgentHub.ActionData[] memory actions
  ) internal pure returns (IAgentHub.ActionData[] memory) {
    IAgentHub.ActionData[] memory buffer = new IAgentHub.ActionData[](actions.length);
    uint256 remaining = MAX_ACTIONS;
    uint256 count = 0;

    for (uint256 i = 0; i < actions.length && remaining > 0; i++) {
      uint256 take = actions[i].markets.length < remaining ? actions[i].markets.length : remaining;
      if (take == 0) continue;

      address[] memory markets = new address[](take);
      for (uint256 j = 0; j < take; j++) markets[j] = actions[i].markets[j];
      buffer[count++] = IAgentHub.ActionData({agentId: actions[i].agentId, markets: markets});
      remaining -= take;
    }

    return _shrink(buffer, count);
  }

  function _enableAgent(uint256 agentId) internal {
    require(agentId < AGENT_HUB.getAgentCount(), InvalidAgent(agentId));
    require(_enabledAgents.add(agentId), AgentStatusUnchanged(agentId, true));

    emit AgentStatusUpdated(agentId, true);
  }

  function _shrink(
    IAgentHub.ActionData[] memory buffer,
    uint256 count
  ) internal pure returns (IAgentHub.ActionData[] memory result) {
    result = new IAgentHub.ActionData[](count);
    for (uint256 i = 0; i < count; i++) result[i] = buffer[i];
  }
}
