// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {RefreshRewardsReceiver} from '../../src/RefreshRewardsReceiver.sol';

/// @dev Exposes `_needsRefresh` and `_isFactoryStataToken` to the tests.
contract RefreshRewardsReceiverHarness is RefreshRewardsReceiver {
  constructor(
    address initialOwner_,
    address initialGuardian_,
    address[] memory initialFactories_
  ) RefreshRewardsReceiver(initialOwner_, initialGuardian_, initialFactories_) {}

  function needsRefresh(address stataToken) external view returns (bool) {
    return _needsRefresh(stataToken);
  }

  function isFactoryStataToken(address factory, address stataToken) external view returns (bool) {
    return _isFactoryStataToken(factory, stataToken);
  }
}
