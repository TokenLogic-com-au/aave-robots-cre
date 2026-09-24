import {getNetwork} from '@chainlink/cre-sdk';
import type {Address} from 'viem';
import type {Config} from '../types';

export type ChainConfig = {
  chainName: string;
  chainSelector: bigint;
  receiver: Address;
  dataProviderV3: Address;
  collector: Address;
  priceOracle: Address;
  corePoolV3: Address;
  primePoolV3?: Address;
  v2?: {dataProvider: Address; corePool: Address};
};

export function parseChainConfig(config: Config): ChainConfig | null {
  const network = getNetwork({
    chainFamily: 'evm',
    chainSelectorName: config.chainName,
    isTestnet: config.isTestnet,
  });
  if (!network || config.receiver === '') return null;
  const {receiver, dataProviderV3, collector, priceOracle, corePoolV3, primePoolV3} = config;
  return {
    chainName: config.chainName,
    chainSelector: network.chainSelector.selector,
    receiver,
    dataProviderV3,
    collector,
    priceOracle,
    corePoolV3,
    primePoolV3,
    v2:
      config.dataProviderV2 && config.corePoolV2
        ? {dataProvider: config.dataProviderV2, corePool: config.corePoolV2}
        : undefined,
  };
}

export function toTokenSet(tokens: string[]): Set<string> {
  return new Set(tokens.map((t) => t.toLowerCase()));
}

export function destinationPool(
  key: string,
  chain: ChainConfig,
  primeTokens: Set<string>,
): {pool: Address; label: 'prime' | 'core'} {
  if (chain.primePoolV3 && primeTokens.has(key)) return {pool: chain.primePoolV3, label: 'prime'};
  return {pool: chain.corePoolV3, label: 'core'};
}
