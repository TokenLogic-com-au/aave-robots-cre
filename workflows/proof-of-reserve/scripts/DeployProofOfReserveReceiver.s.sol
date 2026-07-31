// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from 'forge-std/Script.sol';

import {GovernanceV3Avalanche} from 'aave-address-book/GovernanceV3Avalanche.sol';

import {ProofOfReserveReceiver} from '../src/ProofOfReserveReceiver.sol';

// make deploy-proof-of-reserve env=Avalanche [dry=1]
contract DeployProofOfReserveReceiver is Script {
  function run() external returns (address) {
    address owner = GovernanceV3Avalanche.EXECUTOR_LVL_1;
    address guardian = GovernanceV3Avalanche.GOVERNANCE_GUARDIAN;
    require(owner != address(0), 'invalid owner');
    require(guardian != address(0), 'invalid guardian');
    vm.startBroadcast();
    ProofOfReserveReceiver receiver = new ProofOfReserveReceiver(owner, guardian);
    vm.stopBroadcast();
    console.log('ProofOfReserveReceiver deployed at:', address(receiver));
    console.log('Owner:', owner);
    console.log('Guardian:', guardian);
    return address(receiver);
  }
}
