// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {WorkflowsBase} from 'aave-cre/WorkflowsBase.sol';
import {GasCappedWorkflowsBase} from 'aave-cre/GasCappedWorkflowsBase.sol';
import {IdDenylist} from 'aave-cre/IdDenylist.sol';

contract MockRobot is WorkflowsBase {
  event Reported(bytes metadata, bytes report);

  constructor(address owner_, address guardian_) WorkflowsBase(owner_, guardian_) {}

  function _onReport(bytes calldata metadata, bytes calldata report) internal override {
    emit Reported(metadata, report);
  }

  /// @dev Echoes `checkData` back as `performData`; upkeep is needed unless it is empty.
  function _checkUpkeep(
    bytes calldata checkData
  ) internal pure override returns (bool, bytes memory) {
    return (checkData.length > 0, checkData);
  }
}

contract MockGasCappedRobot is GasCappedWorkflowsBase {
  event Reported(bytes report);

  constructor(
    address oracle_,
    uint256 maxGasPrice_,
    address owner_,
    address guardian_
  ) WorkflowsBase(owner_, guardian_) GasCappedWorkflowsBase(oracle_, maxGasPrice_) {}

  function _onReport(bytes calldata, bytes calldata report) internal override {
    emit Reported(report);
  }

  function _checkUpkeep(bytes calldata) internal pure override returns (bool, bytes memory) {
    return (true, hex'01');
  }
}

/// @dev Governance robot shape: gas capped, with per-id exclusion. Reports the ids in
/// `checkData` that are not disabled and executes the ones in `report` that are not.
contract MockIdDenylistRobot is GasCappedWorkflowsBase, IdDenylist {
  event Executed(uint256 id);

  constructor(
    address oracle_,
    uint256 maxGasPrice_,
    address owner_,
    address guardian_
  ) WorkflowsBase(owner_, guardian_) GasCappedWorkflowsBase(oracle_, maxGasPrice_) {}

  function _onReport(bytes calldata, bytes calldata report) internal override {
    uint256[] memory ids = abi.decode(report, (uint256[]));
    for (uint256 i = 0; i < ids.length; i++) {
      if (!isIdDisabled(ids[i])) emit Executed(ids[i]);
    }
  }

  function _checkUpkeep(
    bytes calldata checkData
  ) internal view override returns (bool, bytes memory) {
    uint256[] memory ids = abi.decode(checkData, (uint256[]));
    uint256[] memory buffer = new uint256[](ids.length);
    uint256 count = 0;
    for (uint256 i = 0; i < ids.length; i++) {
      if (!isIdDisabled(ids[i])) buffer[count++] = ids[i];
    }
    uint256[] memory enabled = new uint256[](count);
    for (uint256 i = 0; i < count; i++) enabled[i] = buffer[i];
    return (count > 0, abi.encode(enabled));
  }
}
