// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from 'forge-std/Script.sol';

import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';
import {UmbrellaEthereum} from 'aave-address-book/UmbrellaEthereum.sol';

import {SlashingReceiver} from '../src/SlashingReceiver.sol';

// make deploy-slashing env=Mainnet [dry=1]
contract DeploySlashingReceiver is Script {
  function run() external returns (address) {
    address umbrella = address(UmbrellaEthereum.UMBRELLA);
    address owner = GovernanceV3Ethereum.EXECUTOR_LVL_1;
    address guardian = GovernanceV3Ethereum.GOVERNANCE_GUARDIAN;
    require(umbrella != address(0), 'invalid umbrella');
    require(owner != address(0), 'invalid owner');
    require(guardian != address(0), 'invalid guardian');
    vm.startBroadcast();
    SlashingReceiver receiver = new SlashingReceiver(umbrella, owner, guardian);
    vm.stopBroadcast();
    console.log('SlashingReceiver deployed at:', address(receiver));
    console.log('Umbrella:', umbrella);
    console.log('Owner:', owner);
    console.log('Guardian:', guardian);
    return address(receiver);
  }
}
