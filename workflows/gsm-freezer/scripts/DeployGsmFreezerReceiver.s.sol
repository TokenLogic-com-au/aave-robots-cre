// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';

import {ChainIds} from 'solidity-utils/contracts/utils/ChainHelpers.sol';
import {GhoEthereum} from 'aave-address-book/GhoEthereum.sol';
import {GhoPlasma} from 'aave-address-book/GhoPlasma.sol';
import {AaveV3Ethereum, AaveV3EthereumAssets} from 'aave-address-book/AaveV3Ethereum.sol';
import {AaveV3Plasma, AaveV3PlasmaAssets} from 'aave-address-book/AaveV3Plasma.sol';

import {GovernanceOwners} from '../../shared/scripts/GovernanceOwners.sol';
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
    Freezer[] freezers;
  }

  // Monad is not in the pinned address book yet; values from GhoMonad.sol and AaveV3Monad.sol
  // in https://github.com/bgd-labs/aave-address-book/tree/main/src
  address internal constant MONAD_GSM_USDC = 0x3Cf3779EEf770931543ACd2C7f6ECd1b37E35caB;
  address internal constant MONAD_USDC_UNDERLYING = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
  address internal constant MONAD_POOL_ADDRESSES_PROVIDER =
    0x34793Fb9935F7bB5E5aE920fb963F39063E7A615;

  // Same band as the live `OracleSwapFreezer`s, 8-decimal USD: freeze outside [0.99, 1.01],
  // unfreeze once back within [0.995, 1.005].
  uint256 internal constant FREEZE_LOWER_BOUND = 0.99e8;
  uint256 internal constant FREEZE_UPPER_BOUND = 1.01e8;
  uint256 internal constant UNFREEZE_LOWER_BOUND = 0.995e8;
  uint256 internal constant UNFREEZE_UPPER_BOUND = 1.005e8;

  function run() external returns (address[] memory receivers) {
    DeployConfig memory config = getDeployConfig(block.chainid);
    (address owner, address guardian) = GovernanceOwners.get(block.chainid);
    receivers = new address[](config.freezers.length);

    vm.startBroadcast();
    for (uint256 i = 0; i < config.freezers.length; i++) {
      receivers[i] = address(
        new GsmFreezerReceiver(
          config.freezers[i].gsm,
          config.freezers[i].underlying,
          config.addressesProvider,
          pegBounds(),
          true, // allowUnfreeze
          owner,
          guardian
        )
      );
    }
    vm.stopBroadcast();
  }

  /// Arbitrum is left out: its only GSM (`GhoArbitrum.GSM_USDC`) is seized.
  function getDeployConfig(uint256 chainId) public pure returns (DeployConfig memory config) {
    if (chainId == ChainIds.MAINNET) {
      config.addressesProvider = address(AaveV3Ethereum.POOL_ADDRESSES_PROVIDER);
      config.freezers = new Freezer[](2);
      config.freezers[0] = Freezer(GhoEthereum.GSM_USDC, AaveV3EthereumAssets.USDC_UNDERLYING);
      config.freezers[1] = Freezer(GhoEthereum.GSM_USDT, AaveV3EthereumAssets.USDT_UNDERLYING);
      return config;
    }

    if (chainId == ChainIds.PLASMA) {
      config.addressesProvider = address(AaveV3Plasma.POOL_ADDRESSES_PROVIDER);
      config.freezers = new Freezer[](1);
      config.freezers[0] = Freezer(GhoPlasma.GSM_USDT, AaveV3PlasmaAssets.USDT0_UNDERLYING);
      return config;
    }

    if (chainId == ChainIds.MONAD) {
      config.addressesProvider = MONAD_POOL_ADDRESSES_PROVIDER;
      config.freezers = new Freezer[](1);
      config.freezers[0] = Freezer(MONAD_GSM_USDC, MONAD_USDC_UNDERLYING);
      return config;
    }

    revert('unsupported chain');
  }

  function pegBounds() public pure returns (IGsmFreezerReceiver.Bounds memory) {
    return
      IGsmFreezerReceiver.Bounds({
        freezeLowerBound: FREEZE_LOWER_BOUND,
        freezeUpperBound: FREEZE_UPPER_BOUND,
        unfreezeLowerBound: UNFREEZE_LOWER_BOUND,
        unfreezeUpperBound: UNFREEZE_UPPER_BOUND
      });
  }
}
