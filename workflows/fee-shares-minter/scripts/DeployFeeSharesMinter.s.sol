// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from 'forge-std/Script.sol';

import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';

import {FeeSharesMinter} from '../src/FeeSharesMinter.sol';

// make deploy-fee-shares-minter env=Mainnet [dry=1]
// make deploy-fee-shares-minter env=Devnet  [dry=1]
contract DeployFeeSharesMinter is Script {
  function run() external returns (address) {
    address owner = GovernanceV3Ethereum.EXECUTOR_LVL_1;
    address guardian = GovernanceV3Ethereum.GOVERNANCE_GUARDIAN;
    require(owner != address(0), 'invalid owner');
    require(guardian != address(0), 'invalid guardian');
    vm.startBroadcast();
    FeeSharesMinter minter = new FeeSharesMinter(owner, guardian);
    vm.stopBroadcast();
    console.log('FeeSharesMinter deployed at:', address(minter));
    console.log('Owner:', owner);
    console.log('Guardian:', guardian);
    return address(minter);
  }
}
