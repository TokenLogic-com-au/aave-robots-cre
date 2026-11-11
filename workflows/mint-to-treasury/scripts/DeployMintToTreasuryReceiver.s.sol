// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';

import {ChainIds} from 'solidity-utils/contracts/utils/ChainHelpers.sol';
import {AaveV3Ethereum} from 'aave-address-book/AaveV3Ethereum.sol';
import {AaveV3EthereumLido} from 'aave-address-book/AaveV3EthereumLido.sol';
import {AaveV3EthereumEtherFi} from 'aave-address-book/AaveV3EthereumEtherFi.sol';
import {AaveV3EthereumHorizon} from 'aave-address-book/AaveV3EthereumHorizon.sol';
import {AaveV3Arbitrum} from 'aave-address-book/AaveV3Arbitrum.sol';
import {AaveV3Avalanche} from 'aave-address-book/AaveV3Avalanche.sol';
import {AaveV3BNB} from 'aave-address-book/AaveV3BNB.sol';
import {AaveV3Base} from 'aave-address-book/AaveV3Base.sol';
import {AaveV3Celo} from 'aave-address-book/AaveV3Celo.sol';
import {AaveV3Gnosis} from 'aave-address-book/AaveV3Gnosis.sol';
import {AaveV3InkWhitelabel} from 'aave-address-book/AaveV3InkWhitelabel.sol';
import {AaveV3Linea} from 'aave-address-book/AaveV3Linea.sol';
import {AaveV3Mantle} from 'aave-address-book/AaveV3Mantle.sol';
import {AaveV3MegaEth} from 'aave-address-book/AaveV3MegaEth.sol';
import {AaveV3Optimism} from 'aave-address-book/AaveV3Optimism.sol';
import {AaveV3Plasma} from 'aave-address-book/AaveV3Plasma.sol';
import {AaveV3Polygon} from 'aave-address-book/AaveV3Polygon.sol';
import {AaveV3Scroll} from 'aave-address-book/AaveV3Scroll.sol';
import {AaveV3Sonic} from 'aave-address-book/AaveV3Sonic.sol';
import {AaveV3XLayer} from 'aave-address-book/AaveV3XLayer.sol';
import {AaveV3ZkSync} from 'aave-address-book/AaveV3ZkSync.sol';

import {GovernanceOwners} from '../../shared/scripts/GovernanceOwners.sol';

import {MintToTreasuryReceiver} from '../src/MintToTreasuryReceiver.sol';
import {IMintToTreasuryReceiver} from '../src/IMintToTreasuryReceiver.sol';

// make deploy-mint-to-treasury env=<Mainnet|Arbitrum|...> [dry=1]
contract DeployMintToTreasuryReceiver is Script {
  /// @dev $5,000 in the pools' oracle base currency (8 decimals).
  uint256 public constant INITIAL_USD_THRESHOLD = 5_000e8;

  // AaveV3Monad is not in the pinned address book yet; value from
  // https://github.com/aave-dao/aave-address-book/blob/main/src/AaveV3Monad.sol
  address internal constant MONAD_POOL = 0x69a5F9AD4f96ebf0a0C792dD42a01cC5C0102fef;

  function run() external returns (address) {
    (address owner, address guardian) = GovernanceOwners.get(block.chainid);
    address[] memory pools = getPools(block.chainid);

    IMintToTreasuryReceiver.PoolThreshold[]
      memory thresholds = new IMintToTreasuryReceiver.PoolThreshold[](pools.length);
    for (uint256 i = 0; i < pools.length; i++) {
      thresholds[i] = IMintToTreasuryReceiver.PoolThreshold(pools[i], INITIAL_USD_THRESHOLD);
    }

    vm.startBroadcast();
    MintToTreasuryReceiver receiver = new MintToTreasuryReceiver(owner, guardian, thresholds);
    vm.stopBroadcast();

    return address(receiver);
  }

  /// @dev The chain's live Aave v3 pools. Metis and Soneium are left out: CRE does not
  /// support them.
  function getPools(uint256 chainId) public pure returns (address[] memory pools) {
    if (chainId == ChainIds.MAINNET) {
      pools = new address[](4);
      pools[0] = address(AaveV3Ethereum.POOL);
      pools[1] = address(AaveV3EthereumLido.POOL);
      pools[2] = address(AaveV3EthereumEtherFi.POOL);
      pools[3] = address(AaveV3EthereumHorizon.POOL);
      return pools;
    }
    if (chainId == ChainIds.ARBITRUM) return _one(address(AaveV3Arbitrum.POOL));
    if (chainId == ChainIds.AVALANCHE) return _one(address(AaveV3Avalanche.POOL));
    if (chainId == ChainIds.BNB) return _one(address(AaveV3BNB.POOL));
    if (chainId == ChainIds.BASE) return _one(address(AaveV3Base.POOL));
    if (chainId == ChainIds.CELO) return _one(address(AaveV3Celo.POOL));
    if (chainId == ChainIds.GNOSIS) return _one(address(AaveV3Gnosis.POOL));
    if (chainId == ChainIds.INK) return _one(address(AaveV3InkWhitelabel.POOL));
    if (chainId == ChainIds.LINEA) return _one(address(AaveV3Linea.POOL));
    if (chainId == ChainIds.MANTLE) return _one(address(AaveV3Mantle.POOL));
    if (chainId == ChainIds.MEGAETH) return _one(address(AaveV3MegaEth.POOL));
    if (chainId == ChainIds.MONAD) return _one(MONAD_POOL);
    if (chainId == ChainIds.OPTIMISM) return _one(address(AaveV3Optimism.POOL));
    if (chainId == ChainIds.PLASMA) return _one(address(AaveV3Plasma.POOL));
    if (chainId == ChainIds.POLYGON) return _one(address(AaveV3Polygon.POOL));
    if (chainId == ChainIds.SCROLL) return _one(address(AaveV3Scroll.POOL));
    if (chainId == ChainIds.SONIC) return _one(address(AaveV3Sonic.POOL));
    if (chainId == ChainIds.XLAYER) return _one(address(AaveV3XLayer.POOL));
    if (chainId == ChainIds.ZKSYNC) return _one(address(AaveV3ZkSync.POOL));
    revert('unsupported chain');
  }

  function _one(address pool) internal pure returns (address[] memory pools) {
    pools = new address[](1);
    pools[0] = pool;
  }
}
