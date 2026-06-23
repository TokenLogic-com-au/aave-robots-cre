// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from 'forge-std/Script.sol';

import {AaveV4Ethereum, AaveV4EthereumGetters} from 'aave-address-book/AaveV4Ethereum.sol';
import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';
import {IAccessManagerEnumerable} from 'aave-v4/access/interfaces/IAccessManagerEnumerable.sol';
import {Roles} from 'aave-v4/deployments/utils/libraries/Roles.sol';
import {IHub} from 'aave-v4/hub/interfaces/IHub.sol';

import {FeeSharesMinter} from '../../src/FeeSharesMinter.sol';

// Tenderly devnet setup: grants HUB_FEE_MINTER_ROLE to the deployed
// FeeSharesMinter and calls updateFeesToAssetsThreshold(hub, assetId, 1) for every asset on every
// Aave v4 Ethereum hub so the off-chain workflow has something to mint against.
//
// forge script workflows/fee-shares-minter/scripts/devnet/ConfigureAllHubs.s.sol:ConfigureAllHubs \
//   --rpc-url tenderly_devnet --unlocked --broadcast -vvvv
contract ConfigureAllHubs is Script {
  uint16 internal constant THRESHOLD_BPS = 1;
  address internal constant MINTER = 0x0000000000000000000000000000000000000000; // TODO: deployed minter address

  function run() external {
    IAccessManagerEnumerable accessManager = AaveV4Ethereum.ACCESS_MANAGER;
    address defaultAdmin = accessManager.getRoleMember(Roles.ACCESS_MANAGER_ADMIN_ROLE, 0);

    vm.startBroadcast(defaultAdmin);
    accessManager.grantRole(Roles.HUB_FEE_MINTER_ROLE, MINTER, 0);
    vm.stopBroadcast();

    IHub[] memory hubs = AaveV4EthereumGetters.getAllHubs();
    vm.startBroadcast(GovernanceV3Ethereum.EXECUTOR_LVL_1);
    for (uint256 i = 0; i < hubs.length; i++) {
      IHub hub = hubs[i];
      uint256 assetCount = hub.getAssetCount();
      console.log('hub', address(hub), 'assetCount', assetCount);
      for (uint256 assetId = 0; assetId < assetCount; assetId++) {
        FeeSharesMinter(MINTER).updateFeesToAssetsThreshold(address(hub), assetId, THRESHOLD_BPS);
      }
    }
    vm.stopBroadcast();
  }
}
