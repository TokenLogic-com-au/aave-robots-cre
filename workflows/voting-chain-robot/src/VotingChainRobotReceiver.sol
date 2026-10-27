// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVotingMachineWithProofs} from 'aave-address-book/governance-v3/IVotingMachineWithProofs.sol';
import {IVotingStrategy} from 'aave-address-book/governance-v3/IVotingStrategy.sol';
import {IDataWarehouse} from 'aave-address-book/governance-v3/IDataWarehouse.sol';

import {WorkflowsBase} from 'aave-cre/WorkflowsBase.sol';
import {GasCappedWorkflowsBase} from 'aave-cre/GasCappedWorkflowsBase.sol';
import {IdDenylist} from 'aave-cre/IdDenylist.sol';
import {IVotingChainRobotReceiver} from './IVotingChainRobotReceiver.sol';

/// @title VotingChainRobotReceiver
/// @author Aave Labs
/// @notice Receives reports from the CRE workflow to start and close Governance V3 votes.
/// Native CRE port of BGD's `VotingChainRobotKeeper` / `GasCappedVotingChainRobotKeeper`,
/// without the storage roots requests (the governance storage roots workflow registers them).
/// @dev `onReport` is permissionless: `startProposalVote` and `closeAndSendVote` are too.
contract VotingChainRobotReceiver is IVotingChainRobotReceiver, GasCappedWorkflowsBase, IdDenylist {
  /// @inheritdoc IVotingChainRobotReceiver
  uint256 public constant MAX_ACTIONS = 5;

  /// @inheritdoc IVotingChainRobotReceiver
  uint256 public constant PAGE_SIZE = 20;

  /// @inheritdoc IVotingChainRobotReceiver
  uint256 public constant MAX_PAGES = 5;

  /// @inheritdoc IVotingChainRobotReceiver
  IVotingMachineWithProofs public immutable VOTING_MACHINE;

  /// @inheritdoc IVotingChainRobotReceiver
  IVotingStrategy public immutable VOTING_STRATEGY;

  /// @inheritdoc IVotingChainRobotReceiver
  IDataWarehouse public immutable DATA_WAREHOUSE;

  /// @inheritdoc IVotingChainRobotReceiver
  address public immutable GOVERNANCE;

  /// @param votingMachine_ The voting machine to automate.
  /// @param gasPriceOracle_ The network gas price feed capping `checkUpkeep`, or zero for no cap.
  /// @param maxGasPrice_ The initial max gas price, in wei. Non-zero with an oracle, zero without.
  /// @param initialOwner_ The address of the initial owner.
  /// @param initialGuardian_ The address of the initial guardian.
  constructor(
    address votingMachine_,
    address gasPriceOracle_,
    uint256 maxGasPrice_,
    address initialOwner_,
    address initialGuardian_
  )
    WorkflowsBase(initialOwner_, initialGuardian_)
    GasCappedWorkflowsBase(gasPriceOracle_, maxGasPrice_)
  {
    require(votingMachine_ != address(0), InvalidAddress());

    VOTING_MACHINE = IVotingMachineWithProofs(votingMachine_);
    VOTING_STRATEGY = VOTING_MACHINE.VOTING_STRATEGY();
    DATA_WAREHOUSE = VOTING_MACHINE.DATA_WAREHOUSE();
    GOVERNANCE = VOTING_MACHINE.GOVERNANCE();
  }

  /// @dev Oldest proposal first; skips actions no longer due and catches reverting ones.
  /// Reverts `NoActionCanBePerformed` if nothing ran, so a stale report fails `estimateGas`.
  function _onReport(bytes calldata /* metadata */, bytes calldata report) internal override {
    ActionWithId[] memory actions = abi.decode(report, (ActionWithId[]));
    bool performed = false;

    for (uint256 i = actions.length; i > 0; i--) {
      if (_performAction(actions[i - 1])) performed = true;
    }
    require(performed, NoActionCanBePerformed());
  }

  /// @dev Pages through the proposals from the latest backwards while pages are full, up to
  /// `MAX_PAGES` or `MAX_ACTIONS`.
  function _checkUpkeep(
    bytes calldata /* checkData */
  ) internal view override returns (bool, bytes memory) {
    ActionWithId[] memory buffer = new ActionWithId[](MAX_ACTIONS);
    uint256 count = 0;
    bool fullPage = true;

    for (uint256 page = 0; page < MAX_PAGES && fullPage && count < MAX_ACTIONS; page++) {
      (count, fullPage) = _collectActions(page * PAGE_SIZE, buffer, count);
    }

    if (count == 0) return (false, '');

    ActionWithId[] memory actions = new ActionWithId[](count);
    for (uint256 i = 0; i < count; i++) actions[i] = buffer[i];
    return (true, abi.encode(actions));
  }

  /// @dev Performs `a` if still due and the proposal isn't disabled; returns whether it ran.
  function _performAction(ActionWithId memory a) internal returns (bool) {
    if (isDisabled(a.id)) return false;

    IVotingMachineWithProofs.ProposalState state = VOTING_MACHINE.getProposalState(a.id);

    if (a.action == ProposalAction.PerformCloseAndSendVote) {
      if (!_canCloseAndSendVote(state)) return false;
      try VOTING_MACHINE.closeAndSendVote(a.id) {} catch {
        return false;
      }
    } else {
      if (!_canCreateVote(state, a.id)) return false;
      try VOTING_MACHINE.startProposalVote(a.id) {} catch {
        return false;
      }
    }

    emit ActionSucceeded(a.id, a.action);
    return true;
  }

  /// @dev Appends one page's actions to `actions` from index `count`; returns the new count
  /// and whether the page was full.
  function _collectActions(
    uint256 skip,
    ActionWithId[] memory actions,
    uint256 count
  ) internal view returns (uint256, bool) {
    uint256[] memory proposalIds = VOTING_MACHINE.getProposalsVoteConfigurationIds(skip, PAGE_SIZE);

    for (uint256 i = 0; i < proposalIds.length && count < MAX_ACTIONS; i++) {
      (bool due, ProposalAction action) = _getAction(proposalIds[i]);
      if (due) actions[count++] = ActionWithId(proposalIds[i], action);
    }
    return (count, proposalIds.length == PAGE_SIZE);
  }

  /// @dev The action due on a proposal: start the vote or close it.
  function _getAction(uint256 proposalId) internal view returns (bool, ProposalAction) {
    if (isDisabled(proposalId)) return (false, ProposalAction.PerformCreateVote);

    IVotingMachineWithProofs.ProposalState state = VOTING_MACHINE.getProposalState(proposalId);
    if (_canCloseAndSendVote(state)) return (true, ProposalAction.PerformCloseAndSendVote);
    return (_canCreateVote(state, proposalId), ProposalAction.PerformCreateVote);
  }

  /// @dev The vote isn't created and the roots of its L1 block hash are registered.
  function _canCreateVote(
    IVotingMachineWithProofs.ProposalState state,
    uint256 proposalId
  ) internal view returns (bool) {
    return
      state == IVotingMachineWithProofs.ProposalState.NotCreated &&
      _hasRequiredRoots(
        VOTING_MACHINE.getProposalVoteConfiguration(proposalId).l1ProposalBlockHash
      );
  }

  /// @dev The voting strategy's roots and the governance representatives root, the same checks
  /// as `startProposalVote`.
  function _hasRequiredRoots(bytes32 blockHash) internal view returns (bool) {
    try VOTING_STRATEGY.hasRequiredRoots(blockHash) {
      return DATA_WAREHOUSE.getStorageRoots(GOVERNANCE, blockHash) != bytes32(0);
    } catch {
      return false;
    }
  }

  /// @dev Voting ended and the result wasn't sent to governance yet.
  function _canCloseAndSendVote(
    IVotingMachineWithProofs.ProposalState state
  ) internal pure returns (bool) {
    return state == IVotingMachineWithProofs.ProposalState.Finished;
  }
}
