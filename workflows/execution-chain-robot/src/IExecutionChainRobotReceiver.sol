// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPayloadsControllerCore} from 'aave-address-book/governance-v3/IPayloadsControllerCore.sol';

import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

/// @title IExecutionChainRobotReceiver
/// @notice Robot that executes Governance V3 payloads queued in a chain's PayloadsController
/// once their timelock has passed, optionally only while the network gas price is under a cap.
/// @dev `checkData` is unused (the PayloadsController is an immutable of the contract);
/// `performData` and the `report` are `abi.encode(uint40[] payloadIds)`.
interface IExecutionChainRobotReceiver is IAaveCREReceiver {
  /// @notice Emitted for each payload executed by `onReport`. Same signature as BGD's
  /// `ExecutionChainRobotKeeper` event, so existing indexers keep working.
  /// @param id The executed payload id.
  event ActionSucceeded(uint256 indexed id);

  /// @notice Emitted when a payload is excluded from or included back into automation.
  /// @param payloadId The payload updated.
  /// @param disabled Whether the payload is now excluded from automation.
  event PayloadDisabled(uint40 indexed payloadId, bool disabled);

  /// @notice Emitted when the gas price cap is set.
  /// @param maxGasPrice The new cap, in wei.
  event MaxGasPriceSet(uint256 indexed maxGasPrice);

  /// @notice Thrown when `onReport` runs but no payload in the batch could be executed.
  error NoActionCanBePerformed();

  /// @notice Thrown when the PayloadsController passed to the constructor is the zero address.
  error InvalidPayloadsController();

  /// @notice Thrown when setting a gas price cap on a robot deployed without a gas price oracle.
  error GasPriceCapNotSupported();

  /// @notice Thrown when setting the gas price cap it already has.
  /// @param maxGasPrice The cap that was requested.
  error MaxGasPriceUnchanged(uint256 maxGasPrice);

  /// @notice Thrown when disabling / enabling a payload that already has that status.
  /// @param payloadId The payload updated.
  /// @param disabled The status that was requested.
  error PayloadStatusUnchanged(uint40 payloadId, bool disabled);

  /// @notice The PayloadsController whose payloads this robot executes.
  function PAYLOADS_CONTROLLER() external view returns (IPayloadsControllerCore);

  /// @notice Chainlink gas price feed (`latestAnswer()` in wei) gating `checkUpkeep`, or the
  /// zero address if the robot is not gas capped.
  function GAS_PRICE_ORACLE() external view returns (address);

  /// @notice Max executable payloads returned by a single `checkUpkeep`.
  function MAX_ACTIONS() external pure returns (uint256);

  /// @notice Consecutive non-executable payloads `checkUpkeep` scans past before giving up,
  /// counting back from the latest payload or the last executable one found.
  function MAX_SKIP() external pure returns (uint256);

  /// @notice Exclude a payload from automation. Owner or guardian.
  /// @param payloadId The payload to disable. Must not be disabled already.
  function disablePayload(uint40 payloadId) external;

  /// @notice Include a previously disabled payload back into automation. Owner-only.
  /// @param payloadId The payload to enable. Must be currently disabled.
  function enablePayload(uint40 payloadId) external;

  /// @notice Set the gas price above which `checkUpkeep` stands down. Owner-only.
  /// @param maxGasPrice The new cap, in wei. Must differ from the current one.
  function setMaxGasPrice(uint256 maxGasPrice) external;

  /// @notice Whether a payload is excluded from automation.
  /// @param payloadId The payload to query.
  function isPayloadDisabled(uint40 payloadId) external view returns (bool);

  /// @notice The gas price cap, in wei. Unused when `GAS_PRICE_ORACLE` is the zero address.
  function getMaxGasPrice() external view returns (uint256);

  /// @notice Whether the oracle gas price is at or below the cap. Always true without an oracle.
  function isGasPriceInRange() external view returns (bool);
}
