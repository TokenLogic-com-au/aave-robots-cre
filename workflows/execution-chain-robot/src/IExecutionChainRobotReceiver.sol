// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPayloadsControllerCore} from 'aave-address-book/governance-v3/IPayloadsControllerCore.sol';

import {IGasCappedWorkflowsBase} from 'aave-cre/IGasCappedWorkflowsBase.sol';
import {IIdDenylist} from 'aave-cre/IIdDenylist.sol';

/// @title IExecutionChainRobotReceiver
/// @author Aave Labs
/// @notice Robot that executes Governance V3 payloads queued in a chain's PayloadsController
/// once their timelock has passed, optionally only while the gas price is under a cap. Single
/// payloads can be excluded through `IIdDenylist`.
/// @dev `checkData` is unused; `performData` and the `report` are `abi.encode(uint40[] payloadIds)`.
interface IExecutionChainRobotReceiver is IGasCappedWorkflowsBase, IIdDenylist {
  /// @notice Emitted for each payload executed by `onReport`.
  /// @param id The payload id.
  event ActionSucceeded(uint256 indexed id);

  /// @notice Thrown when the PayloadsController passed to the constructor is the zero address.
  error InvalidPayloadsController();

  /// @notice Thrown when `onReport` runs but no payload in the batch could be executed.
  error NoActionCanBePerformed();

  /// @notice The PayloadsController whose payloads this robot executes.
  function PAYLOADS_CONTROLLER() external view returns (IPayloadsControllerCore);

  /// @notice Max payloads returned by a single `checkUpkeep`.
  function MAX_ACTIONS() external pure returns (uint256);

  /// @notice Consecutive non-executable payloads after which `checkUpkeep` stops scanning back
  /// from the latest payload.
  function MAX_SKIP() external pure returns (uint256);

  /// @notice Max payloads a single `checkUpkeep` scans, bounding its gas whatever the number
  /// of payloads created.
  function MAX_SCANNED_PAYLOADS() external pure returns (uint256);

  /// @notice Gas `checkUpkeep` allows for reading one payload's state; payloads whose state
  /// can't be read within it are skipped.
  function MAX_STATE_READ_GAS() external pure returns (uint256);
}
