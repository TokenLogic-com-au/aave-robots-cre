// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';

import {UmbrellaEthereum} from 'aave-address-book/UmbrellaEthereum.sol';

import {GovernanceOwners} from '../../shared/scripts/GovernanceOwners.sol';
import {SlashingReceiver} from '../src/SlashingReceiver.sol';

// make deploy-slashing env=Mainnet [dry=1]
contract DeploySlashingReceiver is Script {
  function run() external returns (address) {
    address umbrella = address(UmbrellaEthereum.UMBRELLA);
    require(umbrella.code.length > 0, 'umbrella not deployed on this chain');
    (address owner, address guardian) = GovernanceOwners.get(block.chainid);

    vm.startBroadcast();
    SlashingReceiver receiver = new SlashingReceiver(umbrella, owner, guardian);
    vm.stopBroadcast();

    return address(receiver);
  }
}
