// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from 'forge-std/Script.sol';

import {AaveV3Ethereum} from 'aave-address-book/AaveV3Ethereum.sol';
import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';

import {AaveDepositorReceiver} from '../src/AaveDepositorReceiver.sol';
import {AaveDepositorEthereum} from './AaveDepositorEthereum.sol';

// make deploy-aave-depositor env=Mainnet [dry=1]
contract DeployAaveDepositorReceiver is Script {
  function run() external returns (address) {
    address owner = GovernanceV3Ethereum.EXECUTOR_LVL_1;
    address guardian = GovernanceV3Ethereum.GOVERNANCE_GUARDIAN;
    require(owner != address(0), 'invalid owner');
    require(guardian != address(0), 'invalid guardian');
    vm.startBroadcast();
    AaveDepositorReceiver receiver = new AaveDepositorReceiver(
      AaveDepositorEthereum.FORWARDER,
      AaveDepositorEthereum.ROLES,
      AaveV3Ethereum.POOL_EXPOSURE_STEWARD,
      AaveDepositorEthereum.ROLE_KEY,
      owner,
      guardian
    );
    vm.stopBroadcast();
    console.log('AaveDepositorReceiver deployed at:', address(receiver));
    console.log('Owner:', owner);
    console.log('Guardian:', guardian);
    return address(receiver);
  }
}
