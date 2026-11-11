// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IGovernanceCore} from 'aave-address-book/governance-v3/IGovernanceCore.sol';

import {IGasCappedWorkflowsBase} from 'aave-cre/IGasCappedWorkflowsBase.sol';
import {IIdDenylist} from 'aave-cre/IIdDenylist.sol';

/// @title IGovernanceChainRobotReceiver
/// @author Aave Labs
/// @notice Robot that moves Aave Governance V3 proposals forward on the governance chain:
/// activates voting once the cooldown has passed, executes queued proposals and cancels
/// proposals whose creator lost the proposition power. The `IIdDenylist` ids are proposal ids.
/// @dev `checkData` is unused (the Governance is an immutable of the contract); `performData`
/// and the `report` are `abi.encode(ActionWithId[])`, oldest proposal first.
interface IGovernanceChainRobotReceiver is IGasCappedWorkflowsBase, IIdDenylist {
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

  /// @notice Thrown when the Governance or the gas price feed passed to the constructor is
  /// the zero address.
  error InvalidAddress();

  /// @notice Thrown when `onReport` runs but no action in the batch was performed.
  error NoActionCanBePerformed();

  /// @notice The Governance V3 contract the robot acts on.
  function GOVERNANCE() external view returns (IGovernanceCore);

  /// @notice Max actions returned by a single `checkUpkeep`.
  function MAX_ACTIONS() external pure returns (uint256);

  /// @notice `checkUpkeep` stops scanning back once more than `MAX_SKIP` consecutive
  /// proposals are in a final state.
  function MAX_SKIP() external pure returns (uint256);
}
