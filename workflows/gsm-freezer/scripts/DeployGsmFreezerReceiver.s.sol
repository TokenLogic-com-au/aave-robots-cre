// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';

import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';
import {GovernanceV3Plasma} from 'aave-address-book/GovernanceV3Plasma.sol';
import {GhoEthereum} from 'aave-address-book/GhoEthereum.sol';
import {GhoPlasma} from 'aave-address-book/GhoPlasma.sol';
import {AaveV3Ethereum, AaveV3EthereumAssets} from 'aave-address-book/AaveV3Ethereum.sol';
import {AaveV3Plasma, AaveV3PlasmaAssets} from 'aave-address-book/AaveV3Plasma.sol';

import {GsmFreezerReceiver} from '../src/GsmFreezerReceiver.sol';
import {IGsmFreezerReceiver} from '../src/IGsmFreezerReceiver.sol';

// make deploy-gsm-freezer env=Mainnet|Plasma|Monad [dry=1]
contract DeployGsmFreezerReceiver is Script {
  struct Freezer {
    address gsm;
    address underlying;
  }

  struct DeployConfig {
    address addressesProvider;
    address owner;
    address guardian;
    Freezer[] freezers;
  }

  // Monad is not in the pinned address book yet; values from GhoMonad.sol, AaveV3Monad.sol
  // and GovernanceV3Monad.sol in https://github.com/bgd-labs/aave-address-book/tree/main/src
  address internal constant MONAD_GSM_USDC = 0x3Cf3779EEf770931543ACd2C7f6ECd1b37E35caB;
  address internal constant MONAD_USDC_UNDERLYING = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
  address internal constant MONAD_POOL_ADDRESSES_PROVIDER =
    0x34793Fb9935F7bB5E5aE920fb963F39063E7A615;
  address internal constant MONAD_EXECUTOR_LVL_1 = 0xa9d0EAFF48cE1DF468f9eAeb7e628c413343F6A2;
  address internal constant MONAD_GOVERNANCE_GUARDIAN = 0x056E4C4E80D1D14a637ccbD0412CDAAEc5B51F4E;

  function run() external returns (address[] memory receivers) {
    DeployConfig memory config = getDeployConfig(block.chainid);
    receivers = new address[](config.freezers.length);

    vm.startBroadcast();
    for (uint256 i = 0; i < config.freezers.length; i++) {
      receivers[i] = _deploy(config, config.freezers[i]);
    }
    vm.stopBroadcast();
  }

  /// Arbitrum is left out: its only GSM (`GhoArbitrum.GSM_USDC`) is seized.
  function getDeployConfig(uint256 chainId) public pure returns (DeployConfig memory config) {
    if (chainId == 1) {
      config = DeployConfig({
        addressesProvider: address(AaveV3Ethereum.POOL_ADDRESSES_PROVIDER),
        owner: GovernanceV3Ethereum.EXECUTOR_LVL_1,
        guardian: GovernanceV3Ethereum.GOVERNANCE_GUARDIAN,
        freezers: new Freezer[](2)
      });
      config.freezers[0] = Freezer(GhoEthereum.GSM_USDC, AaveV3EthereumAssets.USDC_UNDERLYING);
      config.freezers[1] = Freezer(GhoEthereum.GSM_USDT, AaveV3EthereumAssets.USDT_UNDERLYING);
      return config;
    }

    if (chainId == 9745) {
      config = DeployConfig({
        addressesProvider: address(AaveV3Plasma.POOL_ADDRESSES_PROVIDER),
        owner: GovernanceV3Plasma.EXECUTOR_LVL_1,
        guardian: GovernanceV3Plasma.GOVERNANCE_GUARDIAN,
        freezers: new Freezer[](1)
      });
      config.freezers[0] = Freezer(GhoPlasma.GSM_USDT, AaveV3PlasmaAssets.USDT0_UNDERLYING);
      return config;
    }

    if (chainId == 143) {
      config = DeployConfig({
        addressesProvider: MONAD_POOL_ADDRESSES_PROVIDER,
        owner: MONAD_EXECUTOR_LVL_1,
        guardian: MONAD_GOVERNANCE_GUARDIAN,
        freezers: new Freezer[](1)
      });
      config.freezers[0] = Freezer(MONAD_GSM_USDC, MONAD_USDC_UNDERLYING);
      return config;
    }

    revert('unsupported chain');
  }

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

  function _deploy(DeployConfig memory config, Freezer memory freezer) internal returns (address) {
    require(freezer.gsm != address(0), 'invalid gsm');
    require(freezer.underlying != address(0), 'invalid underlying');
    require(config.addressesProvider != address(0), 'invalid provider');
    require(config.owner != address(0), 'invalid owner');
    require(config.guardian != address(0), 'invalid guardian');

    return
      address(
        new GsmFreezerReceiver(
          freezer.gsm,
          freezer.underlying,
          config.addressesProvider,
          _pegBounds(),
          true,
          config.owner,
          config.guardian
        )
      );
  }
}
