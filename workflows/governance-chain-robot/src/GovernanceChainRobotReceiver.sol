// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGovernanceCore} from 'aave-address-book/governance-v3/IGovernanceCore.sol';

import {WorkflowsBase} from 'aave-cre/WorkflowsBase.sol';
import {GasCappedWorkflowsBase} from 'aave-cre/GasCappedWorkflowsBase.sol';
import {IdDenylist} from 'aave-cre/IdDenylist.sol';
import {IGovernanceChainRobotReceiver} from './IGovernanceChainRobotReceiver.sol';

/// @title GovernanceChainRobotReceiver
/// @author Aave Labs
/// @notice Receives reports from the CRE workflow and activates voting, executes or cancels
/// Aave Governance V3 proposals. Native CRE port of BGD Labs'
/// `GasCappedGovernanceChainRobotKeeper`.
/// @dev Needs no on-chain role or funds: the Governance calls are permissionless and not payable
/// (the CrossChainController pays the a.DI fees).
contract GovernanceChainRobotReceiver is
  GasCappedWorkflowsBase,
  IdDenylist,
  IGovernanceChainRobotReceiver
{
  /// @inheritdoc IGovernanceChainRobotReceiver
  uint256 public constant override MAX_ACTIONS = 5;

  /// @inheritdoc IGovernanceChainRobotReceiver
  uint256 public constant override MAX_SKIP = 20;

  /// @inheritdoc IGovernanceChainRobotReceiver
  IGovernanceCore public immutable override GOVERNANCE;

  /// @param governance_ The Governance V3 contract to act on.
  /// @param gasPriceOracle_ The Chainlink gas price feed. Required: the robot is always capped.
  /// @param maxGasPrice_ The initial maximum gas price, in wei.
  /// @param initialOwner_ The address of the initial owner.
  /// @param initialGuardian_ The address of the initial guardian.
  constructor(
    address governance_,
    address gasPriceOracle_,
    uint256 maxGasPrice_,
    address initialOwner_,
    address initialGuardian_
  )
    WorkflowsBase(initialOwner_, initialGuardian_)
    GasCappedWorkflowsBase(gasPriceOracle_, maxGasPrice_)
  {
    require(governance_ != address(0) && gasPriceOracle_ != address(0), InvalidAddress());

    GOVERNANCE = IGovernanceCore(governance_);
  }

  /// @dev Oldest proposal first; skips disabled or stale actions and logs a reverting call as
  /// `ActionFailed`. Reverts `NoActionCanBePerformed` if nothing was performed.
  function _onReport(bytes calldata /* metadata */, bytes calldata report) internal override {
    ActionWithId[] memory actions = abi.decode(report, (ActionWithId[]));
    bool performed = false;

    for (uint256 i = actions.length; i > 0; i--) {
      ActionWithId memory a = actions[i - 1];
      if (isIdDisabled(a.id) || !_canPerform(GOVERNANCE.getProposal(a.id), a.action)) continue;

      (bool success, bytes memory reason) = address(GOVERNANCE).call(_calldata(a));
      if (success) {
        performed = true;
        emit ActionSucceeded(a.id, a.action);
      } else {
        emit ActionFailed(a.id, a.action, reason);
      }
    }

    require(performed, NoActionCanBePerformed());
  }

  /// @dev Walks back from the latest proposal until `MAX_SKIP + 1` consecutive final proposals
  /// (disabled ones are ignored) or `MAX_ACTIONS` actions. Cancel wins over activate, then execute.
  function _checkUpkeep(
    bytes calldata /* checkData */
  ) internal view override returns (bool, bytes memory) {
    ActionWithId[] memory buffer = new ActionWithId[](MAX_ACTIONS);
    uint256 count = 0;
    uint256 skipCount = 0;
    uint256 index = GOVERNANCE.getProposalsCount();

    while (index != 0 && skipCount <= MAX_SKIP && count < MAX_ACTIONS) {
      uint256 id = --index;
      if (isIdDisabled(id)) continue;

      IGovernanceCore.Proposal memory proposal = GOVERNANCE.getProposal(id);
      if (_isProposalInFinalState(proposal.state)) {
        skipCount++;
        continue;
      }

      skipCount = 0;
      if (_canProposalBeCancelled(proposal)) {
        buffer[count++] = ActionWithId(id, ProposalAction.PerformCancel);
      } else if (_canVotingBeActivated(proposal)) {
        buffer[count++] = ActionWithId(id, ProposalAction.PerformActivateVoting);
      } else if (_canProposalBeExecuted(proposal)) {
        buffer[count++] = ActionWithId(id, ProposalAction.PerformExecute);
      }
    }
    if (count == 0) return (false, '');

    ActionWithId[] memory actions = new ActionWithId[](count);
    for (uint256 i = 0; i < count; i++) actions[i] = buffer[i];
    return (true, abi.encode(actions));
  }

  function _canPerform(
    IGovernanceCore.Proposal memory proposal,
    ProposalAction action
  ) internal view returns (bool) {
    if (action == ProposalAction.PerformCancel) return _canProposalBeCancelled(proposal);
    if (action == ProposalAction.PerformActivateVoting) return _canVotingBeActivated(proposal);
    return _canProposalBeExecuted(proposal);
  }

  /// @dev Open and the creator's power is not above the minimum, when `cancelProposal` is open
  /// to anyone (BGD's keeper uses `<`, missing equality).
  function _canProposalBeCancelled(
    IGovernanceCore.Proposal memory proposal
  ) internal view returns (bool) {
    if (
      proposal.state == IGovernanceCore.State.Null ||
      uint8(proposal.state) >= uint8(IGovernanceCore.State.Executed)
    ) return false;

    uint256 minPower = GOVERNANCE.getVotingConfig(proposal.accessLevel).minPropositionPower *
      GOVERNANCE.PRECISION_DIVIDER();
    return GOVERNANCE.getPowerStrategy().getFullPropositionPower(proposal.creator) <= minPower;
  }

  /// @dev Created and past the cooldown. The creator's power is covered by the cancel check.
  function _canVotingBeActivated(
    IGovernanceCore.Proposal memory proposal
  ) internal view returns (bool) {
    return
      proposal.state == IGovernanceCore.State.Created &&
      block.timestamp - proposal.creationTime >
      GOVERNANCE.getVotingConfig(proposal.accessLevel).coolDownBeforeVotingStart;
  }

  /// @dev Queued, past the Governance cooldown.
  function _canProposalBeExecuted(
    IGovernanceCore.Proposal memory proposal
  ) internal view returns (bool) {
    return
      proposal.state == IGovernanceCore.State.Queued &&
      block.timestamp >= proposal.queuingTime + GOVERNANCE.COOLDOWN_PERIOD();
  }

  function _calldata(ActionWithId memory a) internal pure returns (bytes memory) {
    if (a.action == ProposalAction.PerformCancel) {
      return abi.encodeCall(IGovernanceCore.cancelProposal, (a.id));
    }
    if (a.action == ProposalAction.PerformActivateVoting) {
      return abi.encodeCall(IGovernanceCore.activateVoting, (a.id));
    }
    return abi.encodeCall(IGovernanceCore.executeProposal, (a.id));
  }

  /// @dev Executed, Failed, Cancelled and Expired.
  function _isProposalInFinalState(IGovernanceCore.State state) internal pure returns (bool) {
    return uint8(state) > uint8(IGovernanceCore.State.Queued);
  }
}
