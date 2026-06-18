import type {Hex} from 'viem';
import * as AaveV4Ethereum from '../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV4Ethereum';

export {AaveV4Ethereum};

export const HUBS_BY_CHAIN: Record<string, readonly Hex[]> = {
  'ethereum-mainnet': AaveV4Ethereum.ALL_HUBS as readonly Hex[],
};

export function hubsFor(chainName: string): readonly Hex[] {
  return HUBS_BY_CHAIN[chainName] ?? [];
}
