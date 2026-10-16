// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ExecutionChainRobotReceiver} from '../../src/ExecutionChainRobotReceiver.sol';

/// @dev Exposes `_canPayloadBeExecuted` to the tests.
contract ExecutionChainRobotReceiverHarness is ExecutionChainRobotReceiver {
  constructor(
    address payloadsController_,
    address gasPriceOracle_,
    uint256 maxGasPrice_,
    address initialOwner_,
    address initialGuardian_
  )
    ExecutionChainRobotReceiver(
      payloadsController_,
      gasPriceOracle_,
      maxGasPrice_,
      initialOwner_,
      initialGuardian_
    )
  {}

  function canPayloadBeExecuted(uint40 payloadId) external view returns (bool) {
    return _canPayloadBeExecuted(payloadId);
  }
}
