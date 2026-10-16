// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IVotingMachineWithProofs} from 'aave-address-book/governance-v3/IVotingMachineWithProofs.sol';
import {IVotingStrategy} from 'aave-address-book/governance-v3/IVotingStrategy.sol';
import {IDataWarehouse} from 'aave-address-book/governance-v3/IDataWarehouse.sol';
import {AggregatorInterface} from 'aave-v3-origin/contracts/dependencies/chainlink/AggregatorInterface.sol';

import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

/// @notice BGD's `RootsConsumer` functions used by the robot. It requests the voting
/// chain's storage roots from a Chainlink node operator, which fetches the Ethereum
/// proofs from an API and registers them on the `DataWarehouse`.
interface IRootsConsumer {
  function requestSubmitRoots(bytes32 blockHash) external;

  function getRobotKeeper() external view returns (address);
}

/// @title IVotingChainRobotReceiver
/// @notice Robot automating the Governance V3 voting machine of a voting chain: requests
/// the storage roots a proposal's vote needs, starts the vote once they are registered and
/// closes it (sending the result to Ethereum) once voting ends.
/// @dev `checkData` is unused; `performData` and the `report` are `abi.encode(ActionWithId[])`,
/// the same encoding as BGD's `VotingChainRobotKeeper`.
interface IVotingChainRobotReceiver is IAaveCREReceiver {
  /// @notice Actions the robot performs on a proposal, by priority.
  /// PerformSubmitRoots: `ROOTS_CONSUMER.requestSubmitRoots` for the proposal's L1 block hash.
  /// PerformCreateVote: `VOTING_MACHINE.startProposalVote`.
  /// PerformCloseAndSendVote: `VOTING_MACHINE.closeAndSendVote`.
  enum ProposalAction {
    PerformSubmitRoots,
    PerformCreateVote,
    PerformCloseAndSendVote
  }

  /// @notice An action to perform on a proposal.
  /// @param id The proposal id.
  /// @param action The action to perform.
  struct ActionWithId {
    uint256 id;
    ProposalAction action;
  }

  /// @notice Emitted for each action `onReport` performs.
  /// @param id The proposal id.
  /// @param action The action performed.
  event ActionSucceeded(uint256 indexed id, ProposalAction indexed action);

  /// @notice Emitted when a proposal is excluded from or included back into automation.
  /// @param proposalId The proposal updated.
  /// @param disabled Whether the proposal is now excluded from automation.
  event ProposalAutomationDisabled(uint256 indexed proposalId, bool disabled);

  /// @notice Emitted when the roots request for a block hash is cleared so it can be retried.
  /// @param proposalId The proposal whose block hash was cleared.
  /// @param blockHash The L1 block hash.
  event RootsRequestReset(uint256 indexed proposalId, bytes32 indexed blockHash);

  /// @notice Emitted when the max gas price is updated.
  /// @param maxGasPrice The new max gas price, in wei.
  event MaxGasPriceSet(uint256 maxGasPrice);

  /// @notice Thrown when a constructor address that must be set is zero.
  error InvalidAddress();

  /// @notice Thrown when `onReport` runs but no action in the batch could be performed.
  error NoActionCanBePerformed();

  /// @notice Thrown when disabling / enabling a proposal that already has that status.
  /// @param proposalId The proposal updated.
  /// @param disabled The status that was requested.
  error ProposalStatusUnchanged(uint256 proposalId, bool disabled);

  /// @notice Thrown when retrying the roots request of a proposal whose block hash has none.
  /// @param proposalId The proposal to retry.
  error RootsNotRequested(uint256 proposalId);

  /// @notice Thrown when setting the max gas price it already has.
  /// @param maxGasPrice The value that was requested.
  error MaxGasPriceUnchanged(uint256 maxGasPrice);

  /// @notice Thrown when setting a max gas price on a robot deployed without gas price oracle.
  error GasPriceCapNotSupported();

  /// @notice The voting machine automated by the robot.
  function VOTING_MACHINE() external view returns (IVotingMachineWithProofs);

  /// @notice The voting strategy of the voting machine.
  function VOTING_STRATEGY() external view returns (IVotingStrategy);

  /// @notice The data warehouse of the voting machine.
  function DATA_WAREHOUSE() external view returns (IDataWarehouse);

  /// @notice The Ethereum governance whose representatives storage root a vote needs.
  function GOVERNANCE() external view returns (address);

  /// @notice The `RootsConsumer` the robot requests storage roots from. The robot must be its
  /// robot keeper to request them.
  function ROOTS_CONSUMER() external view returns (IRootsConsumer);

  /// @notice Network gas price feed capping `checkUpkeep`, or zero for no cap.
  function GAS_PRICE_ORACLE() external view returns (AggregatorInterface);

  /// @notice Max actions returned by a single `checkUpkeep`.
  function MAX_ACTIONS() external pure returns (uint256);

  /// @notice Number of proposal ids read per page, from the latest backwards.
  function PAGE_SIZE() external pure returns (uint256);

  /// @notice Exclude a proposal from automation. Owner or guardian.
  /// @param proposalId The proposal to disable. Must not be disabled already.
  function disableAutomation(uint256 proposalId) external;

  /// @notice Include a previously disabled proposal back into automation. Owner-only.
  /// @param proposalId The proposal to enable. Must be currently disabled.
  function enableAutomation(uint256 proposalId) external;

  /// @notice Clear the roots request of a proposal's block hash so the robot requests the
  /// roots again, e.g. after the Chainlink node operator failed to fulfill it. Owner or guardian.
  /// @param proposalId The proposal whose block hash to retry.
  function retrySubmitRoots(uint256 proposalId) external;

  /// @notice Set the gas price above which `checkUpkeep` reports nothing. Owner-only.
  /// @param maxGasPrice The max gas price, in wei. Must differ from the current one.
  function setMaxGasPrice(uint256 maxGasPrice) external;

  /// @notice The gas price above which `checkUpkeep` reports nothing, in wei.
  function getMaxGasPrice() external view returns (uint256);

  /// @notice Whether the network gas price is within `getMaxGasPrice()`. Always true without
  /// gas price oracle.
  function isGasPriceInRange() external view returns (bool);

  /// @notice Whether a proposal is excluded from automation.
  /// @param proposalId The proposal to query.
  function isDisabled(uint256 proposalId) external view returns (bool);

  /// @notice Whether the robot already requested the roots of an L1 block hash.
  /// @param blockHash The L1 block hash to query.
  function isRootsRequested(bytes32 blockHash) external view returns (bool);
}
