// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IVotingMachineWithProofs} from 'aave-address-book/governance-v3/IVotingMachineWithProofs.sol';
import {IVotingStrategy} from 'aave-address-book/governance-v3/IVotingStrategy.sol';
import {IDataWarehouse} from 'aave-address-book/governance-v3/IDataWarehouse.sol';
import {AggregatorInterface} from 'aave-v3-origin/contracts/dependencies/chainlink/AggregatorInterface.sol';

import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

/// @title IVotingChainRobotReceiver
/// @author Aave Labs
/// @notice Robot automating the Governance V3 voting machine of a voting chain: starts a
/// proposal's vote once its storage roots are registered and closes it once voting ends.
/// @dev `checkData` is unused; `performData` and the `report` are `abi.encode(ActionWithId[])`.
interface IVotingChainRobotReceiver is IAaveCREReceiver {
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

  /// @notice Emitted when a proposal is excluded from or included back into automation.
  /// @param id The proposal id.
  /// @param disabled Whether the proposal is now excluded from automation.
  event AutomationDisabled(uint256 indexed id, bool disabled);

  /// @notice Emitted when the max gas price is updated.
  /// @param maxGasPrice The new max gas price, in wei.
  event MaxGasPriceSet(uint256 maxGasPrice);

  /// @notice Thrown when the voting machine passed to the constructor is the zero address.
  error InvalidAddress();

  /// @notice Thrown when `onReport` runs but no action in the batch could be performed.
  error NoActionCanBePerformed();

  /// @notice Thrown when disabling / enabling a proposal that already has that status.
  /// @param id The proposal id.
  error AutomationStatusUnchanged(uint256 id);

  /// @notice Thrown when setting the max gas price it already has.
  error MaxGasPriceUnchanged();

  /// @notice Thrown when deploying with a gas price oracle and a zero max gas price.
  error InvalidMaxGasPrice();

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

  /// @notice Network gas price feed capping `checkUpkeep`, or zero for no cap.
  function GAS_PRICE_ORACLE() external view returns (AggregatorInterface);

  /// @notice Max actions returned by a single `checkUpkeep`.
  function MAX_ACTIONS() external pure returns (uint256);

  /// @notice Number of proposal ids read per page, from the latest backwards.
  function PAGE_SIZE() external pure returns (uint256);

  /// @notice Exclude a proposal from automation. Owner or guardian.
  /// @param id The proposal id. Must not be disabled already.
  function disableAutomation(uint256 id) external;

  /// @notice Include a previously disabled proposal back into automation. Owner-only.
  /// @param id The proposal id. Must be currently disabled.
  function enableAutomation(uint256 id) external;

  /// @notice Set the gas price above which `checkUpkeep` reports nothing. Owner or guardian.
  /// @param maxGasPrice The max gas price, in wei. Must differ from the current one.
  function setMaxGasPrice(uint256 maxGasPrice) external;

  /// @notice The gas price above which `checkUpkeep` reports nothing, in wei.
  function getMaxGasPrice() external view returns (uint256);

  /// @notice Whether the network gas price is within `getMaxGasPrice()`. Always true without
  /// gas price oracle.
  function isGasPriceInRange() external view returns (bool);

  /// @notice Whether a proposal is excluded from automation.
  /// @param id The proposal id.
  function isDisabled(uint256 id) external view returns (bool);
}
