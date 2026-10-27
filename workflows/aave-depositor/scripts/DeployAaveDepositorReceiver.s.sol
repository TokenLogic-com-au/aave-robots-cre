// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';

import {GovernanceOwners} from '../../shared/scripts/GovernanceOwners.sol';

import {AaveDepositorReceiver} from '../src/AaveDepositorReceiver.sol';
import {AaveDepositorNetworks} from './AaveDepositorNetworks.sol';

// make deploy-aave-depositor env=Mainnet|Arbitrum|Base|Optimism|Avalanche|Polygon [dry=1]
contract DeployAaveDepositorReceiver is Script {
  function run() external returns (address) {
    AaveDepositorNetworks.Network memory net = AaveDepositorNetworks.get(block.chainid);
    (address owner, address guardian) = GovernanceOwners.get(block.chainid);

    vm.startBroadcast();
    AaveDepositorReceiver receiver = new AaveDepositorReceiver(
      net.forwarder,
      net.roles,
      net.steward,
      AaveDepositorNetworks.ROLE_KEY,
      owner,
      guardian
    );
    vm.stopBroadcast();

    return address(receiver);
  }
}
