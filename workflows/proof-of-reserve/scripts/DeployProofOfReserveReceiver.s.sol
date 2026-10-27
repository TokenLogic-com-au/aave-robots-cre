// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';

import {ChainIds} from 'solidity-utils/contracts/utils/ChainHelpers.sol';
import {AaveV2Avalanche} from 'aave-address-book/AaveV2Avalanche.sol';
import {AaveV3Avalanche} from 'aave-address-book/AaveV3Avalanche.sol';

import {GovernanceOwners} from '../../shared/scripts/GovernanceOwners.sol';
import {ProofOfReserveReceiver} from '../src/ProofOfReserveReceiver.sol';

// make deploy-proof-of-reserve env=Avalanche [dry=1]
contract DeployProofOfReserveReceiver is Script {
  function run() external returns (address) {
    require(block.chainid == ChainIds.AVALANCHE, 'unsupported chain');
    (address owner, address guardian) = GovernanceOwners.get(block.chainid);
    address[] memory executors = new address[](2);
    executors[0] = AaveV2Avalanche.PROOF_OF_RESERVE;
    executors[1] = AaveV3Avalanche.PROOF_OF_RESERVE;

    vm.startBroadcast();
    ProofOfReserveReceiver receiver = new ProofOfReserveReceiver(owner, guardian, executors);
    vm.stopBroadcast();
    return address(receiver);
  }
}
