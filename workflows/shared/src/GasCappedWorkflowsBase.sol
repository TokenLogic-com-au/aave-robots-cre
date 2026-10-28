// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AggregatorInterface} from 'aave-v3-origin/contracts/dependencies/chainlink/AggregatorInterface.sol';

import {WorkflowsBase} from './WorkflowsBase.sol';
import {IGasCappedWorkflowsBase} from './IGasCappedWorkflowsBase.sol';

/// @title GasCappedWorkflowsBase
/// @author Aave Labs
/// @notice `WorkflowsBase` whose `checkUpkeep` reports no upkeep while the gas price is above
/// a cap, as BGD's `GasCapped*RobotKeeper`s do.
/// @dev Only `checkUpkeep` is gated: a report already in flight still executes.
abstract contract GasCappedWorkflowsBase is WorkflowsBase, IGasCappedWorkflowsBase {
  /// @inheritdoc IGasCappedWorkflowsBase
  address public immutable GAS_PRICE_ORACLE;

  uint256 internal _maxGasPrice;

  /// @param gasPriceOracle_ Chainlink gas price feed, or the zero address for no cap.
  /// @param maxGasPrice_ The initial max gas price, in wei. Non-zero with a feed, zero without.
  constructor(address gasPriceOracle_, uint256 maxGasPrice_) {
    require(gasPriceOracle_ != address(0) || maxGasPrice_ == 0, GasPriceCapNotSupported());
    require(gasPriceOracle_ == address(0) || maxGasPrice_ != 0, InvalidMaxGasPrice());

    GAS_PRICE_ORACLE = gasPriceOracle_;
    if (gasPriceOracle_ != address(0)) {
      _maxGasPrice = maxGasPrice_;
      emit MaxGasPriceSet(maxGasPrice_);
    }
  }

  /// @inheritdoc IGasCappedWorkflowsBase
  function setMaxGasPrice(uint256 maxGasPrice) external onlyOwnerOrGuardian {
    require(GAS_PRICE_ORACLE != address(0), GasPriceCapNotSupported());
    require(maxGasPrice != 0, InvalidMaxGasPrice());
    require(maxGasPrice != _maxGasPrice, MaxGasPriceUnchanged());
    _maxGasPrice = maxGasPrice;
    emit MaxGasPriceSet(maxGasPrice);
  }

  /// @inheritdoc IGasCappedWorkflowsBase
  function getMaxGasPrice() external view returns (uint256) {
    return _maxGasPrice;
  }

  /// @inheritdoc IGasCappedWorkflowsBase
  function isGasPriceInRange() public view returns (bool) {
    if (GAS_PRICE_ORACLE == address(0)) return true;
    int256 gasPrice = AggregatorInterface(GAS_PRICE_ORACLE).latestAnswer();
    return gasPrice >= 0 && uint256(gasPrice) <= _maxGasPrice;
  }

  function _isUpkeepAllowed() internal view virtual override returns (bool) {
    return super._isUpkeepAllowed() && isGasPriceInRange();
  }
}
