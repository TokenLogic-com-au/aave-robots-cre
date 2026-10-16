// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableWithGuardian} from 'solidity-utils/contracts/access-control/OwnableWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';
import {Rescuable} from 'aave-v4/utils/Rescuable.sol';
import {AggregatorInterface} from 'aave-v3-origin/contracts/dependencies/chainlink/AggregatorInterface.sol';
import {IGovernanceCore} from 'aave-address-book/governance-v3/IGovernanceCore.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';
import {IGovernanceChainRobotReceiver} from './IGovernanceChainRobotReceiver.sol';

/// @title GovernanceChainRobotReceiver
/// @author Aave Labs
/// @notice Receives reports from the CRE workflow and activates voting, executes or cancels
/// Aave Governance V3 proposals. Native CRE port of BGD Labs'
/// `GasCappedGovernanceChainRobotKeeper`.
/// @dev Needs no on-chain role: `activateVoting`, `executeProposal` and `cancelProposal` (once
/// the creator lost the proposition power) are permissionless, and none of them takes a fee
/// from the caller (a.DI fees are paid by the CrossChainController).
contract GovernanceChainRobotReceiver is
  IGovernanceChainRobotReceiver,
  OwnableWithGuardian,
  Rescuable
{
  /// @inheritdoc IGovernanceChainRobotReceiver
  IGovernanceCore public immutable override GOVERNANCE;

  /// @inheritdoc IGovernanceChainRobotReceiver
  address public immutable override GAS_PRICE_ORACLE;

  /// @inheritdoc IGovernanceChainRobotReceiver
  uint256 public constant override MAX_ACTIONS = 5;

  /// @inheritdoc IGovernanceChainRobotReceiver
  uint256 public constant override MAX_SKIP = 20;

  uint256 internal _maxGasPrice;

  mapping(uint256 id => bool) internal _disabled;

  /// @param governance_ The Governance V3 contract to act on.
  /// @param gasPriceOracle_ The Chainlink gas price feed.
  /// @param maxGasPrice_ The initial maximum gas price, in wei.
  /// @param initialOwner_ The address of the initial owner.
  /// @param initialGuardian_ The address of the initial guardian.
  constructor(
    address governance_,
    address gasPriceOracle_,
    uint256 maxGasPrice_,
    address initialOwner_,
    address initialGuardian_
  ) OwnableWithGuardian(initialOwner_, initialGuardian_) {
    require(governance_ != address(0) && gasPriceOracle_ != address(0), InvalidAddress());
    GOVERNANCE = IGovernanceCore(governance_);
    GAS_PRICE_ORACLE = gasPriceOracle_;
    _maxGasPrice = maxGasPrice_;
    emit MaxGasPriceSet(maxGasPrice_);
  }

  /// @inheritdoc IGovernanceChainRobotReceiver
  function disableAutomation(uint256 id) external onlyOwnerOrGuardian {
    require(!_disabled[id], ProposalStatusUnchanged(id, true));
    _disabled[id] = true;
    emit ProposalAutomationDisabled(id, true);
  }

  /// @inheritdoc IGovernanceChainRobotReceiver
  function enableAutomation(uint256 id) external onlyOwner {
    require(_disabled[id], ProposalStatusUnchanged(id, false));
    _disabled[id] = false;
    emit ProposalAutomationDisabled(id, false);
  }

  /// @inheritdoc IGovernanceChainRobotReceiver
  function setMaxGasPrice(uint256 maxGasPrice) external onlyOwnerOrGuardian {
    require(maxGasPrice != _maxGasPrice, MaxGasPriceUnchanged());
    _maxGasPrice = maxGasPrice;
    emit MaxGasPriceSet(maxGasPrice);
  }

  /// @inheritdoc IAaveCREReceiver
  /// @dev Same scan as `GovernanceChainRobotKeeper`: walks back from the latest proposal and
  /// stops after `MAX_SKIP` consecutive proposals in a final state (the count resets on every
  /// non-final one; disabled proposals neither count nor reset it) or once `MAX_ACTIONS` are
  /// found. Per proposal, cancel takes precedence over activate voting, then execute.
  function checkUpkeep(
    bytes calldata /* checkData */
  ) external view returns (bool upkeepNeeded, bytes memory performData) {
    if (!isGasPriceInRange()) return (false, '');

    ActionWithId[] memory buffer = new ActionWithId[](MAX_ACTIONS);
    uint256 count = 0;
    uint256 skipCount = 0;
    uint256 index = GOVERNANCE.getProposalsCount();

    while (index != 0 && skipCount <= MAX_SKIP && count < MAX_ACTIONS) {
      uint256 id = --index;
      if (_disabled[id]) continue;

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

  /// @inheritdoc IReceiver
  /// @dev Performs the actions oldest proposal first, skipping disabled proposals and actions
  /// that no longer apply, and catches a reverting Governance call so one proposal can't block
  /// the rest of the batch. Reverts `NoActionCanBePerformed` if nothing was performed, so a
  /// stale report fails `estimateGas`. The gas price cap only gates `checkUpkeep`.
  function onReport(bytes calldata /* metadata */, bytes calldata report) external override {
    ActionWithId[] memory actions = abi.decode(report, (ActionWithId[]));
    bool performed = false;

    for (uint256 i = actions.length; i > 0; i--) {
      ActionWithId memory a = actions[i - 1];
      if (_disabled[a.id] || !_canPerform(GOVERNANCE.getProposal(a.id), a.action)) continue;
      if (_perform(a)) {
        performed = true;
        emit ActionSucceeded(a.id, a.action);
      }
    }
    require(performed, NoActionCanBePerformed());
  }

  /// @inheritdoc IGovernanceChainRobotReceiver
  function isDisabled(uint256 id) external view returns (bool) {
    return _disabled[id];
  }

  /// @inheritdoc IGovernanceChainRobotReceiver
  function getMaxGasPrice() external view returns (uint256) {
    return _maxGasPrice;
  }

  /// @inheritdoc IGovernanceChainRobotReceiver
  function isGasPriceInRange() public view returns (bool) {
    int256 gasPrice = AggregatorInterface(GAS_PRICE_ORACLE).latestAnswer();
    return gasPrice >= 0 && uint256(gasPrice) <= _maxGasPrice;
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return
      interfaceId == type(IReceiver).interfaceId ||
      interfaceId == type(IAaveCREReceiver).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }

  function _perform(ActionWithId memory a) internal returns (bool) {
    if (a.action == ProposalAction.PerformCancel) {
      try GOVERNANCE.cancelProposal(a.id) {
        return true;
      } catch {
        return false;
      }
    }
    if (a.action == ProposalAction.PerformActivateVoting) {
      try GOVERNANCE.activateVoting(a.id) {
        return true;
      } catch {
        return false;
      }
    }
    try GOVERNANCE.executeProposal(a.id) {
      return true;
    } catch {
      return false;
    }
  }

  function _canPerform(
    IGovernanceCore.Proposal memory proposal,
    ProposalAction action
  ) internal view returns (bool) {
    if (action == ProposalAction.PerformCancel) return _canProposalBeCancelled(proposal);
    if (action == ProposalAction.PerformActivateVoting) return _canVotingBeActivated(proposal);
    return _canProposalBeExecuted(proposal);
  }

  /// @dev Executed, Failed, Cancelled and Expired.
  function _isProposalInFinalState(IGovernanceCore.State state) internal pure returns (bool) {
    return uint8(state) > uint8(IGovernanceCore.State.Queued);
  }

  /// @dev Created, past the access level's cooldown. Doesn't check the creator's power:
  /// `checkUpkeep` tries a cancel first.
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

  /// @dev Not yet executed (nor in a later state) and the creator's proposition power is not
  /// above the access level's minimum, the condition under which `cancelProposal` is open to
  /// anyone. BGD's keeper uses a strict `<`, missing the case where both are equal.
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

  /// @inheritdoc Rescuable
  function _rescueGuardian() internal view override returns (address) {
    return owner();
  }
}
