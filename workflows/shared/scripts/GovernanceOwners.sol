// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ChainIds} from 'solidity-utils/contracts/utils/ChainHelpers.sol';
import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';
import {GovernanceV3Avalanche} from 'aave-address-book/GovernanceV3Avalanche.sol';
import {GovernanceV3Polygon} from 'aave-address-book/GovernanceV3Polygon.sol';
import {GovernanceV3Optimism} from 'aave-address-book/GovernanceV3Optimism.sol';
import {GovernanceV3Arbitrum} from 'aave-address-book/GovernanceV3Arbitrum.sol';
import {GovernanceV3Base} from 'aave-address-book/GovernanceV3Base.sol';
import {GovernanceV3BNB} from 'aave-address-book/GovernanceV3BNB.sol';
import {GovernanceV3Plasma} from 'aave-address-book/GovernanceV3Plasma.sol';

/// @title GovernanceOwners
/// @author Aave Labs
/// @notice Owner and guardian of a robot on each chain: the chain's Aave Governance V3 short
/// executor and governance guardian.
library GovernanceOwners {
  // GovernanceV3Monad is not in the pinned address book yet; values from
  // https://github.com/bgd-labs/aave-address-book/blob/main/src/GovernanceV3Monad.sol
  address internal constant MONAD_EXECUTOR_LVL_1 = 0xa9d0EAFF48cE1DF468f9eAeb7e628c413343F6A2;
  address internal constant MONAD_GOVERNANCE_GUARDIAN = 0x056E4C4E80D1D14a637ccbD0412CDAAEc5B51F4E;

  function get(uint256 chainId) internal pure returns (address owner, address guardian) {
    if (chainId == ChainIds.MAINNET) {
      return (GovernanceV3Ethereum.EXECUTOR_LVL_1, GovernanceV3Ethereum.GOVERNANCE_GUARDIAN);
    }
    if (chainId == ChainIds.AVALANCHE) {
      return (GovernanceV3Avalanche.EXECUTOR_LVL_1, GovernanceV3Avalanche.GOVERNANCE_GUARDIAN);
    }
    if (chainId == ChainIds.POLYGON) {
      return (GovernanceV3Polygon.EXECUTOR_LVL_1, GovernanceV3Polygon.GOVERNANCE_GUARDIAN);
    }
    if (chainId == ChainIds.OPTIMISM) {
      return (GovernanceV3Optimism.EXECUTOR_LVL_1, GovernanceV3Optimism.GOVERNANCE_GUARDIAN);
    }
    if (chainId == ChainIds.ARBITRUM) {
      return (GovernanceV3Arbitrum.EXECUTOR_LVL_1, GovernanceV3Arbitrum.GOVERNANCE_GUARDIAN);
    }
    if (chainId == ChainIds.BASE) {
      return (GovernanceV3Base.EXECUTOR_LVL_1, GovernanceV3Base.GOVERNANCE_GUARDIAN);
    }
    if (chainId == ChainIds.BNB) {
      return (GovernanceV3BNB.EXECUTOR_LVL_1, GovernanceV3BNB.GOVERNANCE_GUARDIAN);
    }
    if (chainId == ChainIds.PLASMA) {
      return (GovernanceV3Plasma.EXECUTOR_LVL_1, GovernanceV3Plasma.GOVERNANCE_GUARDIAN);
    }
    if (chainId == ChainIds.MONAD) {
      return (MONAD_EXECUTOR_LVL_1, MONAD_GOVERNANCE_GUARDIAN);
    }
    revert('unsupported chain');
  }
}
