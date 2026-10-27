// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';

import {GovernanceOwners} from '../../shared/scripts/GovernanceOwners.sol';

import {GsmFeeClaimerReceiver} from '../src/GsmFeeClaimerReceiver.sol';

// make deploy-gsm-fee-claimer env=Mainnet|Arbitrum|Plasma|Monad [dry=1]
contract DeployGsmFeeClaimerReceiver is Script {
  function run() external returns (address) {
    (address owner, address guardian) = GovernanceOwners.get(block.chainid);

    vm.startBroadcast();
    GsmFeeClaimerReceiver receiver = new GsmFeeClaimerReceiver(owner, guardian);
    vm.stopBroadcast();

    return address(receiver);
  }
}
