// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPayloadsControllerCore} from 'aave-address-book/governance-v3/IPayloadsControllerCore.sol';

import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

/// @title IExecutionChainRobotReceiver
/// @author Aave Labs
/// @notice Robot that executes Governance V3 payloads queued in a chain's PayloadsController
/// once their timelock has passed, optionally only while the gas price is under a cap.
/// @dev `checkData` is unused; `performData` and the `report` are `abi.encode(uint40[] payloadIds)`.
interface IExecutionChainRobotReceiver is IAaveCREReceiver {
  /// @notice Emitted for each payload executed by `onReport`.
  /// @param id The payload id.
  event ActionSucceeded(uint256 indexed id);

  /// @notice Emitted when a payload is excluded from or included back into automation.
  /// @param id The payload id.
  /// @param disabled Whether the payload is now excluded from automation.
  event AutomationDisabled(uint256 indexed id, bool disabled);

  /// @notice Emitted when the maximum gas price is updated.
  /// @param maxGasPrice The new maximum gas price, in wei.
  event MaxGasPriceSet(uint256 maxGasPrice);

  /// @notice Thrown when `onReport` runs but no payload in the batch could be executed.
  error NoActionCanBePerformed();

  /// @notice Thrown when the PayloadsController passed to the constructor is the zero address.
  error InvalidPayloadsController();

  /// @notice Thrown when setting a gas price cap on a robot deployed without a gas price oracle.
  error GasPriceCapNotSupported();

  /// @notice Thrown when deploying with a gas price oracle and a zero max gas price.
  error InvalidMaxGasPrice();

  /// @notice Thrown when setting the maximum gas price to its current value.
  error MaxGasPriceUnchanged();

  /// @notice Thrown when disabling / enabling a payload that already has that status.
  /// @param id The payload id.
  error AutomationStatusUnchanged(uint256 id);

  /// @notice The PayloadsController whose payloads this robot executes.
  function PAYLOADS_CONTROLLER() external view returns (IPayloadsControllerCore);

  /// @notice Chainlink gas price feed compared against the maximum gas price, or the zero
  /// address if the robot is not gas capped.
  function GAS_PRICE_ORACLE() external view returns (address);

  /// @notice Max payloads returned by a single `checkUpkeep`.
  function MAX_ACTIONS() external pure returns (uint256);

  /// @notice Consecutive non-executable payloads after which `checkUpkeep` stops scanning back
  /// from the latest payload.
  function MAX_SKIP() external pure returns (uint256);

  /// @notice Exclude a payload from automation. Owner or guardian.
  /// @param id The payload id. Must not be disabled already.
  function disableAutomation(uint256 id) external;

  /// @notice Include a previously disabled payload back into automation. Owner-only.
  /// @param id The payload id. Must be currently disabled.
  function enableAutomation(uint256 id) external;

  /// @notice Set the gas price above which `checkUpkeep` reports no upkeep. Owner or guardian.
  /// @param maxGasPrice The maximum gas price, in wei. Must differ from the current one.
  function setMaxGasPrice(uint256 maxGasPrice) external;

  /// @notice Whether a payload is excluded from automation.
  /// @param id The payload id.
  function isDisabled(uint256 id) external view returns (bool);

  /// @notice The gas price above which `checkUpkeep` reports no upkeep, in wei.
  function getMaxGasPrice() external view returns (uint256);

  /// @notice Whether the gas price feed answer is at or below the maximum gas price. Always
  /// true without an oracle.
  function isGasPriceInRange() external view returns (bool);
}
