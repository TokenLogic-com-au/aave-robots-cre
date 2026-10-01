// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';

import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';
import {GhoEthereum} from 'aave-address-book/GhoEthereum.sol';
import {AaveV3Ethereum, AaveV3EthereumAssets} from 'aave-address-book/AaveV3Ethereum.sol';

import {GsmFreezerReceiver} from '../src/GsmFreezerReceiver.sol';
import {IGsmFreezerReceiver} from '../src/IGsmFreezerReceiver.sol';

// make deploy-gsm-freezer env=Mainnet [dry=1]
contract DeployGsmFreezerReceiver is Script {
  // Freeze if the underlying leaves [0.99, 1.01]; unfreeze once back within [0.995, 1.005]. 8-decimal USD.
  function _pegBounds() internal pure returns (IGsmFreezerReceiver.Bounds memory) {
    return
      IGsmFreezerReceiver.Bounds({
        freezeLowerBound: 0.99e8,
        freezeUpperBound: 1.01e8,
        unfreezeLowerBound: 0.995e8,
        unfreezeUpperBound: 1.005e8
      });
  }

  function _deploy(address gsm, address underlying) internal returns (address) {
    address owner = GovernanceV3Ethereum.EXECUTOR_LVL_1;
    address guardian = GovernanceV3Ethereum.GOVERNANCE_GUARDIAN;
    require(gsm != address(0), 'invalid gsm');
    require(underlying != address(0), 'invalid underlying');
    require(address(AaveV3Ethereum.POOL_ADDRESSES_PROVIDER) != address(0), 'invalid provider');
    require(owner != address(0), 'invalid owner');
    require(guardian != address(0), 'invalid guardian');
    return
      address(
        new GsmFreezerReceiver(
          gsm,
          underlying,
          address(AaveV3Ethereum.POOL_ADDRESSES_PROVIDER),
          _pegBounds(),
          true,
          owner,
          guardian
        )
      );
  }

  function run() external returns (address usdcFreezer, address usdtFreezer) {
    vm.startBroadcast();
    usdcFreezer = _deploy(GhoEthereum.GSM_USDC, AaveV3EthereumAssets.USDC_UNDERLYING);
    usdtFreezer = _deploy(GhoEthereum.GSM_USDT, AaveV3EthereumAssets.USDT_UNDERLYING);
    vm.stopBroadcast();
  }
}
