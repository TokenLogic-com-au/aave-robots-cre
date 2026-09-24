// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from 'forge-std/Script.sol';

import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';
import {GovernanceV3Arbitrum} from 'aave-address-book/GovernanceV3Arbitrum.sol';
import {GovernanceV3Plasma} from 'aave-address-book/GovernanceV3Plasma.sol';

import {GsmFeeClaimerReceiver} from '../src/GsmFeeClaimerReceiver.sol';

// make deploy-gsm-fee-claimer env=Mainnet|Arbitrum|Plasma|Monad [dry=1]
contract DeployGsmFeeClaimerReceiver is Script {
  // GovernanceV3Monad is not in the pinned address book yet; values from
  // https://github.com/bgd-labs/aave-address-book/blob/main/src/GovernanceV3Monad.sol
  address internal constant MONAD_EXECUTOR_LVL_1 = 0xa9d0EAFF48cE1DF468f9eAeb7e628c413343F6A2;
  address internal constant MONAD_GOVERNANCE_GUARDIAN = 0x056E4C4E80D1D14a637ccbD0412CDAAEc5B51F4E;

  function run() external returns (address) {
    (address owner, address guardian) = _governance(block.chainid);
    vm.startBroadcast();
    GsmFeeClaimerReceiver receiver = new GsmFeeClaimerReceiver(owner, guardian);
    vm.stopBroadcast();
    console.log('GsmFeeClaimerReceiver deployed at:', address(receiver));
    console.log('Chain:', block.chainid);
    console.log('Owner:', owner);
    console.log('Guardian:', guardian);
    return address(receiver);
  }

  function _governance(uint256 chainId) internal pure returns (address owner, address guardian) {
    if (chainId == 1) {
      return (GovernanceV3Ethereum.EXECUTOR_LVL_1, GovernanceV3Ethereum.GOVERNANCE_GUARDIAN);
    }
    if (chainId == 42161) {
      return (GovernanceV3Arbitrum.EXECUTOR_LVL_1, GovernanceV3Arbitrum.GOVERNANCE_GUARDIAN);
    }
    if (chainId == 9745) {
      return (GovernanceV3Plasma.EXECUTOR_LVL_1, GovernanceV3Plasma.GOVERNANCE_GUARDIAN);
    }
    if (chainId == 143) {
      return (MONAD_EXECUTOR_LVL_1, MONAD_GOVERNANCE_GUARDIAN);
    }
    revert('unsupported chain');
  }
}
