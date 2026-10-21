// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IGovernanceCore} from 'aave-address-book/governance-v3/IGovernanceCore.sol';

import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

/// @title IGovernanceChainRobotReceiver
/// @author Aave Labs
/// @notice Robot that moves Aave Governance V3 proposals forward on the governance chain:
/// activates voting once the cooldown has passed, executes queued proposals and cancels
/// proposals whose creator lost the proposition power.
/// @dev `checkData` is unused (the Governance is an immutable of the contract); `performData`
/// and the `report` are `abi.encode(ActionWithId[])`, newest proposal first.
interface IGovernanceChainRobotReceiver is IAaveCREReceiver {
  /// @notice Action performed on a proposal.
  enum ProposalAction {
    PerformActivateVoting,
    PerformExecute,
    PerformCancel
  }

  /// @notice Action to perform on a proposal.
  /// @param id The proposal id.
  /// @param action The action to perform.
  struct ActionWithId {
    uint256 id;
    ProposalAction action;
  }

  /// @notice Emitted for each action performed by `onReport`.
  /// @param id The proposal id.
  /// @param action The action performed.
  event ActionSucceeded(uint256 indexed id, ProposalAction indexed action);

  /// @notice Emitted when a Governance call reverts inside `onReport`.
  /// @param id The proposal id.
  /// @param action The action attempted.
  /// @param reason The revert data.
  event ActionFailed(uint256 indexed id, ProposalAction action, bytes reason);

  /// @notice Emitted when a proposal is excluded from or included back into automation.
  /// @param id The proposal id.
  /// @param disabled Whether the proposal is now excluded from automation.
  event AutomationDisabled(uint256 indexed id, bool disabled);

  /// @notice Emitted when the maximum gas price is updated.
  /// @param maxGasPrice The new maximum gas price, in wei.
  event MaxGasPriceSet(uint256 maxGasPrice);

  /// @notice Thrown when `onReport` runs but no action in the batch was performed.
  error NoActionCanBePerformed();

  /// @notice Thrown when a constructor address is zero.
  error InvalidAddress();

  /// @notice Thrown when disabling / enabling a proposal that already has that status.
  /// @param id The proposal id.
  error AutomationStatusUnchanged(uint256 id);

  /// @notice Thrown when setting the maximum gas price to its current value.
  error MaxGasPriceUnchanged();

  /// @notice Thrown when deploying with a zero max gas price.
  error InvalidMaxGasPrice();

  /// @notice The Governance V3 contract the robot acts on.
  function GOVERNANCE() external view returns (IGovernanceCore);

  /// @notice Chainlink gas price feed compared against the maximum gas price.
  function GAS_PRICE_ORACLE() external view returns (address);

  /// @notice Max actions returned by a single `checkUpkeep`.
  function MAX_ACTIONS() external pure returns (uint256);

  /// @notice `checkUpkeep` stops scanning back once more than `MAX_SKIP` consecutive
  /// proposals are in a final state.
  function MAX_SKIP() external pure returns (uint256);

  /// @notice Exclude a proposal from automation. Owner or guardian.
  /// @param id The proposal id. Must not be disabled already.
  function disableAutomation(uint256 id) external;

  /// @notice Include a previously disabled proposal back into automation. Owner-only.
  /// @param id The proposal id. Must be currently disabled.
  function enableAutomation(uint256 id) external;

  /// @notice Set the gas price above which `checkUpkeep` reports no upkeep. Owner or guardian.
  /// @param maxGasPrice The maximum gas price, in wei. Must differ from the current one.
  function setMaxGasPrice(uint256 maxGasPrice) external;

  /// @notice Whether a proposal is excluded from automation.
  /// @param id The proposal id.
  function isDisabled(uint256 id) external view returns (bool);

  /// @notice The gas price above which `checkUpkeep` reports no upkeep, in wei.
  function getMaxGasPrice() external view returns (uint256);

  /// @notice Whether the gas price feed answer is at or below the maximum gas price.
  function isGasPriceInRange() external view returns (bool);
}
