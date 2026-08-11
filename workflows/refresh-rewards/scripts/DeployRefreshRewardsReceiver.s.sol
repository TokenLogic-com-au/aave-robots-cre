// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from 'forge-std/Script.sol';

import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';

import {RefreshRewardsReceiver} from '../src/RefreshRewardsReceiver.sol';

// make deploy-refresh-rewards env=Mainnet [dry=1]
contract DeployRefreshRewardsReceiver is Script {
  function run() external returns (address) {
    address owner = GovernanceV3Ethereum.EXECUTOR_LVL_1;
    address guardian = GovernanceV3Ethereum.GOVERNANCE_GUARDIAN;
    require(owner != address(0), 'invalid owner');
    require(guardian != address(0), 'invalid guardian');
    vm.startBroadcast();
    RefreshRewardsReceiver receiver = new RefreshRewardsReceiver(owner, guardian);
    vm.stopBroadcast();
    console.log('RefreshRewardsReceiver deployed at:', address(receiver));
    console.log('Owner:', owner);
    console.log('Guardian:', guardian);
    return address(receiver);
  }
}
