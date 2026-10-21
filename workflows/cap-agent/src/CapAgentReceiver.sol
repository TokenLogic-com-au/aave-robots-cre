// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableWithGuardian} from 'solidity-utils/contracts/access-control/OwnableWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';
import {EnumerableSet} from 'openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol';
import {Rescuable} from 'aave-v4/utils/Rescuable.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';
import {ICapAgentReceiver, IAgentHub} from './ICapAgentReceiver.sol';

/// @title CapAgentReceiver
/// @author Aave Labs
/// @notice Receives reports from the CRE workflow and injects pending Risk Oracle updates
/// through the AgentHub. Native CRE port of BGD's `ChainlinkAgentHub`.
/// @dev `onReport` is permissionless: `AgentHub.execute` re-validates every update.
contract CapAgentReceiver is ICapAgentReceiver, OwnableWithGuardian, Rescuable {
  using EnumerableSet for EnumerableSet.UintSet;

  /// @inheritdoc ICapAgentReceiver
  IAgentHub public immutable override AGENT_HUB;

  /// @inheritdoc ICapAgentReceiver
  uint256 public constant override MAX_ACTIONS = 10;

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
  ) OwnableWithGuardian(initialOwner_, initialGuardian_) {
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

  /// @inheritdoc IAaveCREReceiver
  function checkUpkeep(
    bytes calldata /* checkData */
  ) external view returns (bool upkeepNeeded, bytes memory performData) {
    uint256[] memory agentIds = _executableAgents();
    if (agentIds.length == 0) return (false, '');

    (bool shouldExecute, IAgentHub.ActionData[] memory actions) = AGENT_HUB.check(agentIds);
    if (!shouldExecute) return (false, '');

    return (true, abi.encode(_capActions(actions)));
  }

  /// @inheritdoc IReceiver
  /// @dev Drops actions for agents not enabled on this robot. A stale report reverts in
  /// `AgentHub.execute` (`NoActionCanBePerformed`), so it fails `estimateGas`.
  function onReport(bytes calldata /* metadata */, bytes calldata report) external override {
    IAgentHub.ActionData[] memory actions = _enabledActions(
      abi.decode(report, (IAgentHub.ActionData[]))
    );
    require(actions.length > 0, NoActionsToExecute());

    AGENT_HUB.execute(actions);
  }

  /// @inheritdoc ICapAgentReceiver
  function isAgentEnabled(uint256 agentId) external view returns (bool) {
    return _enabledAgents.contains(agentId);
  }

  /// @inheritdoc ICapAgentReceiver
  function getEnabledAgents() external view returns (uint256[] memory) {
    return _enabledAgents.values();
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return
      interfaceId == type(IReceiver).interfaceId ||
      interfaceId == type(IAaveCREReceiver).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }

  function _enableAgent(uint256 agentId) internal {
    require(agentId < AGENT_HUB.getAgentCount(), InvalidAgent(agentId));
    require(_enabledAgents.add(agentId), AgentStatusUnchanged(agentId, true));
    emit AgentStatusUpdated(agentId, true);
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

  function _shrink(
    IAgentHub.ActionData[] memory buffer,
    uint256 count
  ) internal pure returns (IAgentHub.ActionData[] memory result) {
    result = new IAgentHub.ActionData[](count);
    for (uint256 i = 0; i < count; i++) result[i] = buffer[i];
  }

  /// @inheritdoc Rescuable
  function _rescueGuardian() internal view override returns (address) {
    return owner();
  }
}
