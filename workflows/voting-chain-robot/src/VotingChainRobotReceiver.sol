// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableWithGuardian} from 'solidity-utils/contracts/access-control/OwnableWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';
import {Rescuable} from 'aave-v4/utils/Rescuable.sol';
import {IVotingMachineWithProofs} from 'aave-address-book/governance-v3/IVotingMachineWithProofs.sol';
import {IVotingStrategy} from 'aave-address-book/governance-v3/IVotingStrategy.sol';
import {IDataWarehouse} from 'aave-address-book/governance-v3/IDataWarehouse.sol';
import {AggregatorInterface} from 'aave-v3-origin/contracts/dependencies/chainlink/AggregatorInterface.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';
import {IVotingChainRobotReceiver} from './IVotingChainRobotReceiver.sol';

/// @title VotingChainRobotReceiver
/// @author Aave Labs
/// @notice Receives reports from the CRE workflow and automates a Governance V3 voting
/// machine: starts votes once their storage roots are registered and closes finished ones.
/// Native CRE port of BGD Labs' `VotingChainRobotKeeper` and, with a gas price oracle, of
/// `GasCappedVotingChainRobotKeeper`, without their storage roots requests: the roots are
/// registered on the `DataWarehouse` by the governance storage roots CRE workflow.
/// @dev `onReport` is permissionless, like the keeper's `performUpkeep`: `startProposalVote`
/// and `closeAndSendVote` are permissionless themselves.
contract VotingChainRobotReceiver is IVotingChainRobotReceiver, OwnableWithGuardian, Rescuable {
  /// @inheritdoc IVotingChainRobotReceiver
  IVotingMachineWithProofs public immutable override VOTING_MACHINE;

  /// @inheritdoc IVotingChainRobotReceiver
  IVotingStrategy public immutable override VOTING_STRATEGY;

  /// @inheritdoc IVotingChainRobotReceiver
  IDataWarehouse public immutable override DATA_WAREHOUSE;

  /// @inheritdoc IVotingChainRobotReceiver
  address public immutable override GOVERNANCE;

  /// @inheritdoc IVotingChainRobotReceiver
  AggregatorInterface public immutable override GAS_PRICE_ORACLE;

  /// @inheritdoc IVotingChainRobotReceiver
  uint256 public constant override MAX_ACTIONS = 5;

  /// @inheritdoc IVotingChainRobotReceiver
  uint256 public constant override PAGE_SIZE = 20;

  uint256 internal _maxGasPrice;

  // A denylist rather than an allowlist: every new proposal must be automated without
  // any configuration.
  mapping(uint256 proposalId => bool) internal _disabled;

  /// @param votingMachine_ The voting machine to automate.
  /// @param gasPriceOracle_ The network gas price feed capping `checkUpkeep`, or zero for no cap.
  /// @param maxGasPrice_ The initial max gas price, in wei. Must be zero without gas price oracle.
  /// @param initialOwner_ The address of the initial owner.
  /// @param initialGuardian_ The address of the initial guardian.
  constructor(
    address votingMachine_,
    address gasPriceOracle_,
    uint256 maxGasPrice_,
    address initialOwner_,
    address initialGuardian_
  ) OwnableWithGuardian(initialOwner_, initialGuardian_) {
    require(votingMachine_ != address(0), InvalidAddress());

    require(gasPriceOracle_ != address(0) || maxGasPrice_ == 0, GasPriceCapNotSupported());

    VOTING_MACHINE = IVotingMachineWithProofs(votingMachine_);
    VOTING_STRATEGY = VOTING_MACHINE.VOTING_STRATEGY();
    DATA_WAREHOUSE = VOTING_MACHINE.DATA_WAREHOUSE();
    GOVERNANCE = VOTING_MACHINE.GOVERNANCE();
    GAS_PRICE_ORACLE = AggregatorInterface(gasPriceOracle_);

    if (gasPriceOracle_ != address(0)) {
      _maxGasPrice = maxGasPrice_;
      emit MaxGasPriceSet(maxGasPrice_);
    }
  }

  /// @inheritdoc IVotingChainRobotReceiver
  function disableAutomation(uint256 proposalId) external onlyOwnerOrGuardian {
    require(!_disabled[proposalId], ProposalStatusUnchanged(proposalId, true));
    _disabled[proposalId] = true;
    emit ProposalAutomationDisabled(proposalId, true);
  }

  /// @inheritdoc IVotingChainRobotReceiver
  function enableAutomation(uint256 proposalId) external onlyOwner {
    require(_disabled[proposalId], ProposalStatusUnchanged(proposalId, false));
    _disabled[proposalId] = false;
    emit ProposalAutomationDisabled(proposalId, false);
  }

  /// @inheritdoc IVotingChainRobotReceiver
  function setMaxGasPrice(uint256 maxGasPrice) external onlyOwnerOrGuardian {
    require(address(GAS_PRICE_ORACLE) != address(0), GasPriceCapNotSupported());
    require(maxGasPrice != _maxGasPrice, MaxGasPriceUnchanged(maxGasPrice));
    _maxGasPrice = maxGasPrice;
    emit MaxGasPriceSet(maxGasPrice);
  }

  /// @inheritdoc IAaveCREReceiver
  /// @dev Reads the proposals with a vote configuration from the latest backwards, one page of
  /// `PAGE_SIZE` at a time, and reads the next page only while the current one had an action
  /// (as BGD's keeper does). Stops at `MAX_ACTIONS`. Reports nothing while the gas price is
  /// above the cap.
  function checkUpkeep(
    bytes calldata /* checkData */
  ) external view returns (bool upkeepNeeded, bytes memory performData) {
    if (!isGasPriceInRange()) return (false, '');

    ActionWithId[] memory buffer = new ActionWithId[](MAX_ACTIONS);
    uint256 count = 0;
    uint256 countBefore;
    uint256 skip = 0;

    do {
      countBefore = count;
      count = _collectActions(skip, buffer, count);
      skip += PAGE_SIZE;
    } while (count > countBefore && count < MAX_ACTIONS);

    if (count == 0) return (false, '');

    ActionWithId[] memory actions = new ActionWithId[](count);
    for (uint256 i = 0; i < count; i++) actions[i] = buffer[i];
    return (true, abi.encode(actions));
  }

  /// @inheritdoc IReceiver
  /// @dev Performs the actions oldest proposal first, each only if it still applies and the
  /// proposal is not disabled. A reverting action is caught so it can't block the rest of the
  /// batch. Reverts `NoActionCanBePerformed` if nothing was performed, so a stale report fails
  /// `estimateGas`.
  function onReport(bytes calldata /* metadata */, bytes calldata report) external override {
    ActionWithId[] memory actions = abi.decode(report, (ActionWithId[]));
    bool performed = false;

    for (uint256 i = actions.length; i > 0; i--) {
      if (_performAction(actions[i - 1])) performed = true;
    }
    require(performed, NoActionCanBePerformed());
  }

  /// @inheritdoc IVotingChainRobotReceiver
  function getMaxGasPrice() external view returns (uint256) {
    return _maxGasPrice;
  }

  /// @inheritdoc IVotingChainRobotReceiver
  function isGasPriceInRange() public view returns (bool) {
    if (address(GAS_PRICE_ORACLE) == address(0)) return true;
    return uint256(GAS_PRICE_ORACLE.latestAnswer()) <= _maxGasPrice;
  }

  /// @inheritdoc IVotingChainRobotReceiver
  function isDisabled(uint256 proposalId) external view returns (bool) {
    return _disabled[proposalId];
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return
      interfaceId == type(IReceiver).interfaceId ||
      interfaceId == type(IAaveCREReceiver).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }

  /// @dev Appends the actions of one page of proposal ids to `actions`, from index `count`,
  /// and returns the new count.
  function _collectActions(
    uint256 skip,
    ActionWithId[] memory actions,
    uint256 count
  ) internal view returns (uint256) {
    uint256[] memory proposalIds = VOTING_MACHINE.getProposalsVoteConfigurationIds(skip, PAGE_SIZE);

    for (uint256 i = 0; i < proposalIds.length && count < MAX_ACTIONS; i++) {
      (bool due, ProposalAction action) = _getAction(proposalIds[i]);
      if (due) actions[count++] = ActionWithId(proposalIds[i], action);
    }
    return count;
  }

  /// @dev The action due on a proposal: start the vote or close it.
  function _getAction(uint256 proposalId) internal view returns (bool, ProposalAction) {
    if (_disabled[proposalId]) return (false, ProposalAction.PerformCreateVote);

    IVotingMachineWithProofs.ProposalState state = VOTING_MACHINE.getProposalState(proposalId);
    if (_canCloseAndSendVote(state)) return (true, ProposalAction.PerformCloseAndSendVote);
    return (_canCreateVote(state, proposalId), ProposalAction.PerformCreateVote);
  }

  /// @dev Performs `a` if it still applies and the proposal is not disabled. Returns whether
  /// it was performed.
  function _performAction(ActionWithId memory a) internal returns (bool) {
    if (_disabled[a.id]) return false;

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

  /// @dev The vote isn't created and every root `startProposalVote` checks is registered for
  /// the proposal's L1 block hash.
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

  /// @dev Voting ended and the result wasn't sent to governance yet.
  function _canCloseAndSendVote(
    IVotingMachineWithProofs.ProposalState state
  ) internal pure returns (bool) {
    return state == IVotingMachineWithProofs.ProposalState.Finished;
  }

  /// @dev Whether the voting tokens' roots (and the stkAAVE exchange rate slot) and the
  /// governance representatives root of `blockHash` are registered, the same checks as
  /// `startProposalVote`.
  function _hasRequiredRoots(bytes32 blockHash) internal view returns (bool) {
    try VOTING_STRATEGY.hasRequiredRoots(blockHash) {
      return DATA_WAREHOUSE.getStorageRoots(GOVERNANCE, blockHash) != bytes32(0);
    } catch {
      return false;
    }
  }

  /// @inheritdoc Rescuable
  function _rescueGuardian() internal view override returns (address) {
    return owner();
  }
}
