import {describe, expect, test} from 'bun:test';

import {fitsWriteQuota, maxWriteGas} from './gas';

describe('fitsWriteQuota', () => {
  test('uses the raised quota on Ethereum and the default one elsewhere', () => {
    expect(maxWriteGas('ethereum-mainnet')).toBe(16_777_216n);
    expect(maxWriteGas('avalanche-mainnet')).toBe(10_000_000n);
  });

  test('leaves room for the forwarder overhead', () => {
    expect(fitsWriteQuota('avalanche-mainnet', 9_597_657n)).toBe(true);
    expect(fitsWriteQuota('avalanche-mainnet', 9_597_658n)).toBe(false);
    expect(fitsWriteQuota('ethereum-mainnet', 9_597_658n)).toBe(true);
  });
});
