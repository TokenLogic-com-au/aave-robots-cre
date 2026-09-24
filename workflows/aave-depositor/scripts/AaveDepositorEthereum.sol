// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Ethereum constants shared by the deploy script and the fork test.
library AaveDepositorEthereum {
  /// @dev Chainlink KeystoneForwarder for ethereum-mainnet (`cre workflow supported-chains`).
  address internal constant FORWARDER = 0x0b93082D9b3C7C97fAcd250082899BAcf3af3885;
  /// @dev Zodiac Roles Modifier owned by the Aave Finance Committee Safe.
  address internal constant ROLES = 0x1D5579B363806CCecc35115ab8F56EECf6610ea9;
  /// @dev Role scoped to `depositV3` and `migrateV2toV3` on the PoolExposureSteward.
  bytes32 internal constant ROLE_KEY = 'aave_depositor';
}
