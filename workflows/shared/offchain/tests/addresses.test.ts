import {describe, expect, test} from 'bun:test';
import {getNetwork} from '@chainlink/cre-sdk';
import type {Hex} from 'viem';

import * as AaveV3Ethereum from '../../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3Ethereum';
import * as AaveV3EthereumLido from '../../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3EthereumLido';
import * as AaveV3EthereumEtherFi from '../../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3EthereumEtherFi';
import * as AaveV3EthereumHorizon from '../../../../lib/aave-helpers/lib/aave-address-book/src/ts/AaveV3EthereumHorizon';
import {V3_POOLS_BY_CHAIN, v3PoolsFor} from '../addresses';

describe('v3PoolsFor', () => {
  test('returns the four Ethereum pools from the address book', () => {
    expect(v3PoolsFor('ethereum-mainnet')).toEqual([
      AaveV3Ethereum.POOL,
      AaveV3EthereumLido.POOL,
      AaveV3EthereumEtherFi.POOL,
      AaveV3EthereumHorizon.POOL,
    ] as Hex[]);
  });

  test('returns an empty array for an unknown chain', () => {
    expect(v3PoolsFor('made-up-chain')).toEqual([]);
  });

  test('every chain name is known to the cre-sdk', () => {
    for (const chainName of Object.keys(V3_POOLS_BY_CHAIN)) {
      expect(
        getNetwork({chainFamily: 'evm', chainSelectorName: chainName, isTestnet: false}),
      ).toBeDefined();
    }
  });
});
