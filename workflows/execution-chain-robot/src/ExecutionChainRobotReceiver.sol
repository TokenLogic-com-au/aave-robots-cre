// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableWithGuardian} from 'solidity-utils/contracts/access-control/OwnableWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';
import {Rescuable} from 'aave-v4/utils/Rescuable.sol';
import {AggregatorInterface} from 'aave-v3-origin/contracts/dependencies/chainlink/AggregatorInterface.sol';
import {IPayloadsControllerCore} from 'aave-address-book/governance-v3/IPayloadsControllerCore.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';
import {IExecutionChainRobotReceiver} from './IExecutionChainRobotReceiver.sol';

/// @title ExecutionChainRobotReceiver
/// @author Aave Labs
/// @notice Native CRE port of BGD's `ExecutionChainRobotKeeper` and, with a gas price oracle,
/// `GasCappedExecutionChainRobotKeeper`: executes Governance V3 payloads past their timelock.
/// @dev Needs no on-chain role: `PayloadsController.executePayload` is permissionless.
contract ExecutionChainRobotReceiver is
  IExecutionChainRobotReceiver,
  OwnableWithGuardian,
  Rescuable
{
  /// @inheritdoc IExecutionChainRobotReceiver
  IPayloadsControllerCore public immutable override PAYLOADS_CONTROLLER;

  /// @inheritdoc IExecutionChainRobotReceiver
  address public immutable override GAS_PRICE_ORACLE;

  /// @inheritdoc IExecutionChainRobotReceiver
  uint256 public constant override MAX_ACTIONS = 5;

  /// @inheritdoc IExecutionChainRobotReceiver
  uint256 public constant override MAX_SKIP = 20;

  uint256 internal _maxGasPrice;

  mapping(uint256 id => bool) internal _disabled;

  /// @param payloadsController_ The PayloadsController whose payloads to execute.
  /// @param gasPriceOracle_ Chainlink gas price feed, or the zero address for no cap.
  /// @param maxGasPrice_ The initial gas price cap, in wei. Must be 0 without an oracle.
  /// @param initialOwner_ The address of the initial owner.
  /// @param initialGuardian_ The address of the initial guardian.
  constructor(
    address payloadsController_,
    address gasPriceOracle_,
    uint256 maxGasPrice_,
    address initialOwner_,
    address initialGuardian_
  ) OwnableWithGuardian(initialOwner_, initialGuardian_) {
    require(payloadsController_ != address(0), InvalidPayloadsController());
    require(gasPriceOracle_ != address(0) || maxGasPrice_ == 0, GasPriceCapNotSupported());
    require(gasPriceOracle_ == address(0) || maxGasPrice_ != 0, InvalidMaxGasPrice());

    PAYLOADS_CONTROLLER = IPayloadsControllerCore(payloadsController_);
    GAS_PRICE_ORACLE = gasPriceOracle_;
    if (gasPriceOracle_ != address(0)) {
      _maxGasPrice = maxGasPrice_;
      emit MaxGasPriceSet(maxGasPrice_);
    }
  }

  /// @inheritdoc IExecutionChainRobotReceiver
  function disableAutomation(uint256 id) external onlyOwnerOrGuardian {
    require(!_disabled[id], AutomationStatusUnchanged(id));

    _disabled[id] = true;
    emit AutomationDisabled(id, true);
  }

  /// @inheritdoc IExecutionChainRobotReceiver
  function enableAutomation(uint256 id) external onlyOwner {
    require(_disabled[id], AutomationStatusUnchanged(id));

    _disabled[id] = false;
    emit AutomationDisabled(id, false);
  }

  /// @inheritdoc IExecutionChainRobotReceiver
  function setMaxGasPrice(uint256 maxGasPrice) external onlyOwnerOrGuardian {
    require(GAS_PRICE_ORACLE != address(0), GasPriceCapNotSupported());
    require(maxGasPrice != _maxGasPrice, MaxGasPriceUnchanged());

    _maxGasPrice = maxGasPrice;
    emit MaxGasPriceSet(maxGasPrice);
  }

  /// @inheritdoc IAaveCREReceiver
  /// @dev Walks back from the latest payload until `MAX_SKIP` + 1 consecutive non-executable
  /// ones (an executable one resets the count, disabled ones aren't counted) or `MAX_ACTIONS` found.
  function checkUpkeep(
    bytes calldata /* checkData */
  ) external view returns (bool upkeepNeeded, bytes memory performData) {
    if (!isGasPriceInRange()) return (false, '');

    uint40[] memory found = new uint40[](MAX_ACTIONS);
    uint256 count = 0;
    uint256 skipCount = 0;
    uint40 index = PAYLOADS_CONTROLLER.getPayloadsCount();

    while (index != 0 && skipCount <= MAX_SKIP && count < MAX_ACTIONS) {
      index--;
      if (_disabled[index]) continue;
      if (_canPayloadBeExecuted(index)) {
        found[count++] = index;
        skipCount = 0;
      } else {
        skipCount++;
      }
    }
    if (count == 0) return (false, '');

    // Oldest first, so payloads of one proposal execute in creation order.
    uint40[] memory payloadIds = new uint40[](count);
    for (uint256 i = 0; i < count; i++) payloadIds[i] = found[count - 1 - i];
    return (true, abi.encode(payloadIds));
  }

  /// @inheritdoc IReceiver
  /// @dev Permissionless. Executes each payload still executable and not disabled; reverts
  /// `NoActionCanBePerformed` if none was, so a stale report fails `estimateGas`.
  function onReport(bytes calldata /* metadata */, bytes calldata report) external override {
    uint40[] memory payloadIds = abi.decode(report, (uint40[]));
    bool executed = false;

    for (uint256 i = 0; i < payloadIds.length; i++) {
      uint40 payloadId = payloadIds[i];
      if (_disabled[payloadId] || !_canPayloadBeExecuted(payloadId)) continue;
      PAYLOADS_CONTROLLER.executePayload(payloadId);
      executed = true;
      emit ActionSucceeded(payloadId);
    }
    require(executed, NoActionCanBePerformed());
  }

  /// @inheritdoc IExecutionChainRobotReceiver
  function isDisabled(uint256 id) external view returns (bool) {
    return _disabled[id];
  }

  /// @inheritdoc IExecutionChainRobotReceiver
  function getMaxGasPrice() external view returns (uint256) {
    return _maxGasPrice;
  }

  /// @inheritdoc IExecutionChainRobotReceiver
  function isGasPriceInRange() public view returns (bool) {
    if (GAS_PRICE_ORACLE == address(0)) return true;
    int256 gasPrice = AggregatorInterface(GAS_PRICE_ORACLE).latestAnswer();
    return gasPrice >= 0 && uint256(gasPrice) <= _maxGasPrice;
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return
      interfaceId == type(IReceiver).interfaceId ||
      interfaceId == type(IAaveCREReceiver).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }

  /// @dev Same condition `executePayload` enforces: queued (not expired) and past its delay.
  function _canPayloadBeExecuted(uint40 payloadId) internal view returns (bool) {
    IPayloadsControllerCore.Payload memory payload = PAYLOADS_CONTROLLER.getPayloadById(payloadId);
    return
      payload.state == IPayloadsControllerCore.PayloadState.Queued &&
      block.timestamp > payload.queuedAt + payload.delay;
  }

  /// @inheritdoc Rescuable
  function _rescueGuardian() internal view override returns (address) {
    return owner();
  }
}
