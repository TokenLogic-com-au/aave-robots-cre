// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IWorkflowsBase} from './IWorkflowsBase.sol';

/// @title IGasCappedWorkflowsBase
/// @author Aave Labs
/// @notice Robot whose `checkUpkeep` reports no upkeep while a Chainlink gas price feed is
/// above a cap. Deployed without a feed, the robot is not capped.
interface IGasCappedWorkflowsBase is IWorkflowsBase {
  /// @notice Emitted when the maximum gas price is updated.
  /// @param maxGasPrice The new maximum gas price, in wei.
  event MaxGasPriceSet(uint256 maxGasPrice);

  /// @notice Thrown when setting a gas price cap on a robot deployed without a gas price feed.
  error GasPriceCapNotSupported();

  /// @notice Thrown when the max gas price of a capped robot is set to zero, which would stop
  /// every upkeep.
  error InvalidMaxGasPrice();

  /// @notice Thrown when setting the maximum gas price to its current value.
  error MaxGasPriceUnchanged();

  /// @notice Set the gas price above which `checkUpkeep` reports no upkeep. Owner or guardian.
  /// @param maxGasPrice The maximum gas price, in wei. Non-zero, and different from the current one.
  function setMaxGasPrice(uint256 maxGasPrice) external;

  /// @notice Chainlink gas price feed compared against the maximum gas price, or the zero
  /// address if the robot is not gas capped.
  function GAS_PRICE_ORACLE() external view returns (address);

  /// @notice The gas price above which `checkUpkeep` reports no upkeep, in wei.
  function getMaxGasPrice() external view returns (uint256);

  /// @notice Whether the gas price feed answer is at or below the maximum gas price. Always
  /// true without a feed.
  function isGasPriceInRange() external view returns (bool);
}
