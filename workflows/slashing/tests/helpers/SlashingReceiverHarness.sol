// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SlashingReceiver} from '../../src/SlashingReceiver.sol';

/// @dev Exposes `_isSlashable` and `_canStakeBeSlashed` to the tests.
contract SlashingReceiverHarness is SlashingReceiver {
  constructor(
    address umbrella_,
    address initialOwner_,
    address initialGuardian_
  ) SlashingReceiver(umbrella_, initialOwner_, initialGuardian_) {}

  function isSlashable(address reserve) external view returns (bool) {
    return _isSlashable(reserve);
  }

  function canStakeBeSlashed(address reserve, address stkToken) external view returns (bool) {
    return _canStakeBeSlashed(reserve, stkToken);
  }
}
