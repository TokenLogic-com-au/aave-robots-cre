// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from 'forge-std/Script.sol';

import {AaveDepositorReceiver} from '../src/AaveDepositorReceiver.sol';
import {AaveDepositorNetworks} from './AaveDepositorNetworks.sol';

// make deploy-aave-depositor env=Mainnet|Arbitrum|Base|Optimism [dry=1]
contract DeployAaveDepositorReceiver is Script {
  function run() external returns (address) {
    AaveDepositorNetworks.Network memory net = AaveDepositorNetworks.get(block.chainid);

    vm.startBroadcast();
    AaveDepositorReceiver receiver = new AaveDepositorReceiver(
      net.forwarder,
      net.roles,
      net.steward,
      net.roleKey,
      net.owner,
      net.guardian
    );
    vm.stopBroadcast();

    console.log('AaveDepositorReceiver deployed at:', address(receiver));
    console.log('Chain:', block.chainid);
    console.log('Steward:', net.steward);
    console.log('Owner:', net.owner);
    console.log('Guardian:', net.guardian);
    return address(receiver);
  }
}
