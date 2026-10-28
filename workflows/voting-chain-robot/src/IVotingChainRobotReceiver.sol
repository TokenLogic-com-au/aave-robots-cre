// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IVotingMachineWithProofs} from 'aave-address-book/governance-v3/IVotingMachineWithProofs.sol';
import {IVotingStrategy} from 'aave-address-book/governance-v3/IVotingStrategy.sol';
import {IDataWarehouse} from 'aave-address-book/governance-v3/IDataWarehouse.sol';

import {IGasCappedWorkflowsBase} from 'aave-cre/IGasCappedWorkflowsBase.sol';
import {IIdDenylist} from 'aave-cre/IIdDenylist.sol';

/// @title IVotingChainRobotReceiver
/// @author Aave Labs
/// @notice Robot automating the Governance V3 voting machine of a voting chain: starts a
/// proposal's vote once its storage roots are registered and closes it once voting ends.
/// @dev `checkData` is unused; `performData` and the `report` are `abi.encode(ActionWithId[])`.
interface IVotingChainRobotReceiver is IGasCappedWorkflowsBase, IIdDenylist {
  /// @notice Actions the robot performs on a proposal.
  /// PerformCreateVote: `VOTING_MACHINE.startProposalVote`.
  /// PerformCloseAndSendVote: `VOTING_MACHINE.closeAndSendVote`.
  enum ProposalAction {
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

  /// @notice Thrown when the voting machine passed to the constructor is the zero address.
  error InvalidAddress();

  /// @notice Thrown when `onReport` runs but no action in the batch could be performed.
  error NoActionCanBePerformed();

  /// @notice Max actions returned by a single `checkUpkeep`.
  function MAX_ACTIONS() external pure returns (uint256);

  /// @notice Number of proposal ids read per page, from the latest backwards.
  function PAGE_SIZE() external pure returns (uint256);

  /// @notice Max pages read by a single `checkUpkeep`, bounding its gas.
  function MAX_PAGES() external pure returns (uint256);

  /// @notice The voting machine automated by the robot.
  function VOTING_MACHINE() external view returns (IVotingMachineWithProofs);

  /// @notice The voting strategy of the voting machine.
  function VOTING_STRATEGY() external view returns (IVotingStrategy);

  /// @notice The data warehouse of the voting machine.
  function DATA_WAREHOUSE() external view returns (IDataWarehouse);

  /// @notice The Ethereum governance whose representatives storage root a vote needs.
  function GOVERNANCE() external view returns (address);
}
