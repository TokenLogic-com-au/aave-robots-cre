import type {Hex} from 'viem';
import * as AaveV4Ethereum from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV4Ethereum';
import * as AaveV3Ethereum from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3Ethereum';
import * as AaveV3EthereumLido from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3EthereumLido';
import * as AaveV3EthereumEtherFi from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3EthereumEtherFi';
import * as AaveV3EthereumHorizon from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3EthereumHorizon';
import * as AaveV3Arbitrum from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3Arbitrum';
import * as AaveV3Avalanche from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3Avalanche';
import * as AaveV3BNB from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3BNB';
import * as AaveV3Base from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3Base';
import * as AaveV3Celo from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3Celo';
import * as AaveV3Gnosis from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3Gnosis';
import * as AaveV3InkWhitelabel from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3InkWhitelabel';
import * as AaveV3Linea from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3Linea';
import * as AaveV3Mantle from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3Mantle';
import * as AaveV3MegaEth from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3MegaEth';
import * as AaveV3Optimism from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3Optimism';
import * as AaveV3Plasma from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3Plasma';
import * as AaveV3Polygon from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3Polygon';
import * as AaveV3Scroll from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3Scroll';
import * as AaveV3Sonic from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3Sonic';
import * as AaveV3XLayer from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3XLayer';
import * as AaveV3ZkSync from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3ZkSync';

export {AaveV4Ethereum};

export const HUBS_BY_CHAIN: Record<string, readonly Hex[]> = {
  'ethereum-mainnet': AaveV4Ethereum.ALL_HUBS as readonly Hex[],
};

export function hubsFor(chainName: string): readonly Hex[] {
  return HUBS_BY_CHAIN[chainName] ?? [];
}

// Monad is not in the pinned address book yet; POOL from AaveV3Monad.ts in
// https://github.com/bgd-labs/aave-address-book/tree/main/src/ts
const AAVE_V3_MONAD_POOL: Hex = '0x69a5F9AD4f96ebf0a0C792dD42a01cC5C0102fef';

// Live Aave v3 pools per CRE chain name.
export const V3_POOLS_BY_CHAIN: Record<string, readonly Hex[]> = {
  'ethereum-mainnet': [
    AaveV3Ethereum.POOL,
    AaveV3EthereumLido.POOL,
    AaveV3EthereumEtherFi.POOL,
    AaveV3EthereumHorizon.POOL,
  ] as Hex[],
  'ethereum-mainnet-arbitrum-1': [AaveV3Arbitrum.POOL as Hex],
  'avalanche-mainnet': [AaveV3Avalanche.POOL as Hex],
  'binance_smart_chain-mainnet': [AaveV3BNB.POOL as Hex],
  'ethereum-mainnet-base-1': [AaveV3Base.POOL as Hex],
  'celo-mainnet': [AaveV3Celo.POOL as Hex],
  'gnosis_chain-mainnet': [AaveV3Gnosis.POOL as Hex],
  'ethereum-mainnet-ink-1': [AaveV3InkWhitelabel.POOL as Hex],
  'ethereum-mainnet-linea-1': [AaveV3Linea.POOL as Hex],
  'ethereum-mainnet-mantle-1': [AaveV3Mantle.POOL as Hex],
  'megaeth-mainnet': [AaveV3MegaEth.POOL as Hex],
  'monad-mainnet': [AAVE_V3_MONAD_POOL],
  'ethereum-mainnet-optimism-1': [AaveV3Optimism.POOL as Hex],
  'plasma-mainnet': [AaveV3Plasma.POOL as Hex],
  'polygon-mainnet': [AaveV3Polygon.POOL as Hex],
  'ethereum-mainnet-scroll-1': [AaveV3Scroll.POOL as Hex],
  'sonic-mainnet': [AaveV3Sonic.POOL as Hex],
  'ethereum-mainnet-xlayer-1': [AaveV3XLayer.POOL as Hex],
  'ethereum-mainnet-zksync-1': [AaveV3ZkSync.POOL as Hex],
};

export function v3PoolsFor(chainName: string): readonly Hex[] {
  return V3_POOLS_BY_CHAIN[chainName] ?? [];
}
