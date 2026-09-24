// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AaveV3Ethereum} from 'aave-address-book/AaveV3Ethereum.sol';
import {AaveV3Arbitrum} from 'aave-address-book/AaveV3Arbitrum.sol';
import {AaveV3Base} from 'aave-address-book/AaveV3Base.sol';
import {AaveV3Optimism} from 'aave-address-book/AaveV3Optimism.sol';
import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';
import {GovernanceV3Arbitrum} from 'aave-address-book/GovernanceV3Arbitrum.sol';
import {GovernanceV3Base} from 'aave-address-book/GovernanceV3Base.sol';
import {GovernanceV3Optimism} from 'aave-address-book/GovernanceV3Optimism.sol';

/// @notice Per-network constructor arguments for `AaveDepositorReceiver`, shared by the
/// deploy script and the fork test.
/// @dev Forwarders come from `cre workflow supported-chains`; the Roles Modifiers are the
/// Aave Finance Committee's (owner and avatar `AFC_SAFE` on every chain), with the
/// `aave_depositor` role scoped to the chain's PoolExposureSteward.
library AaveDepositorNetworks {
  struct Network {
    address forwarder;
    address roles;
    address steward;
    bytes32 roleKey;
    address owner;
    address guardian;
  }

  bytes32 internal constant ROLE_KEY = 'aave_depositor';

  address internal constant ETHEREUM_FORWARDER = 0x0b93082D9b3C7C97fAcd250082899BAcf3af3885;
  address internal constant ETHEREUM_ROLES = 0x1D5579B363806CCecc35115ab8F56EECf6610ea9;

  // Arbitrum, Base and Optimism share one KeystoneForwarder deployment.
  address internal constant L2_FORWARDER = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482;
  address internal constant ARBITRUM_ROLES = 0xE2e4a8995440b70E810f0D94ae971B25829DC938;
  address internal constant BASE_ROLES = 0xBA25175FD3da510Ad9B1f550eA211A230Ca5F80d;
  address internal constant OPTIMISM_ROLES = 0x4b33Fd24ab9f9AA1dFFEa634E3Af64143C082436;

  function get(uint256 chainId) internal pure returns (Network memory) {
    if (chainId == 1) {
      return
        Network(
          ETHEREUM_FORWARDER,
          ETHEREUM_ROLES,
          AaveV3Ethereum.POOL_EXPOSURE_STEWARD,
          ROLE_KEY,
          GovernanceV3Ethereum.EXECUTOR_LVL_1,
          GovernanceV3Ethereum.GOVERNANCE_GUARDIAN
        );
    }
    if (chainId == 42161) {
      return
        Network(
          L2_FORWARDER,
          ARBITRUM_ROLES,
          AaveV3Arbitrum.POOL_EXPOSURE_STEWARD,
          ROLE_KEY,
          GovernanceV3Arbitrum.EXECUTOR_LVL_1,
          GovernanceV3Arbitrum.GOVERNANCE_GUARDIAN
        );
    }
    if (chainId == 8453) {
      return
        Network(
          L2_FORWARDER,
          BASE_ROLES,
          AaveV3Base.POOL_EXPOSURE_STEWARD,
          ROLE_KEY,
          GovernanceV3Base.EXECUTOR_LVL_1,
          GovernanceV3Base.GOVERNANCE_GUARDIAN
        );
    }
    if (chainId == 10) {
      return
        Network(
          L2_FORWARDER,
          OPTIMISM_ROLES,
          AaveV3Optimism.POOL_EXPOSURE_STEWARD,
          ROLE_KEY,
          GovernanceV3Optimism.EXECUTOR_LVL_1,
          GovernanceV3Optimism.GOVERNANCE_GUARDIAN
        );
    }
    revert('unsupported chain');
  }
}
