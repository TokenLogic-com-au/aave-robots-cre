// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from 'forge-std/Script.sol';

import {GovernanceV3Avalanche} from 'aave-address-book/GovernanceV3Avalanche.sol';
import {AaveV2Avalanche} from 'aave-address-book/AaveV2Avalanche.sol';
import {AaveV3Avalanche} from 'aave-address-book/AaveV3Avalanche.sol';

import {ProofOfReserveReceiver} from '../src/ProofOfReserveReceiver.sol';

// make deploy-proof-of-reserve env=Avalanche [dry=1]
contract DeployProofOfReserveReceiver is Script {
  function run() external returns (address) {
    address owner = GovernanceV3Avalanche.EXECUTOR_LVL_1;
    address guardian = GovernanceV3Avalanche.GOVERNANCE_GUARDIAN;
    require(owner != address(0), 'invalid owner');
    require(guardian != address(0), 'invalid guardian');
    address[] memory executors = new address[](2);
    executors[0] = AaveV2Avalanche.PROOF_OF_RESERVE;
    executors[1] = AaveV3Avalanche.PROOF_OF_RESERVE;
    vm.startBroadcast();
    ProofOfReserveReceiver receiver = new ProofOfReserveReceiver(owner, guardian, executors);
    vm.stopBroadcast();
    console.log('ProofOfReserveReceiver deployed at:', address(receiver));
    console.log('Owner:', owner);
    console.log('Guardian:', guardian);
    for (uint256 i = 0; i < executors.length; i++) {
      console.log('Enabled executor:', executors[i]);
    }
    return address(receiver);
  }
}
