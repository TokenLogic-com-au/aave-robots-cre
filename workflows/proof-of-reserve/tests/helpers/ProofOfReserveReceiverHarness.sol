// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ProofOfReserveReceiver} from '../../src/ProofOfReserveReceiver.sol';

/// @dev Exposes `_shouldExecute` to the tests.
contract ProofOfReserveReceiverHarness is ProofOfReserveReceiver {
  constructor(
    address initialOwner_,
    address initialGuardian_,
    address[] memory initialExecutors_
  ) ProofOfReserveReceiver(initialOwner_, initialGuardian_, initialExecutors_) {}

  function shouldExecute(address executor) external view returns (bool) {
    return _shouldExecute(executor);
  }
}
