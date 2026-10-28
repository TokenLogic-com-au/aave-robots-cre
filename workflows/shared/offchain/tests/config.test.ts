import {describe, expect, test} from 'bun:test';
import {z} from 'zod';

import {
  addressSchema,
  configSchema,
  createConfigSchema,
  networkSchema,
  uintSchema,
} from '../config';

const LOWER = '0x5300a1a15135ea4dc7ad5a167152c01efc9b192a';
const CHECKSUMMED = '0x5300A1a15135EA4dc7aD5a167152C01EFc9b192A';

describe('addressSchema', () => {
  test('normalizes to the checksummed address', () => {
    expect(addressSchema.parse(LOWER)).toBe(CHECKSUMMED);
  });

  test('rejects a non-address', () => {
    expect(addressSchema.safeParse('0x1234').success).toBe(false);
  });
});

describe('uintSchema', () => {
  test('parses a decimal string beyond 2^53', () => {
    expect(uintSchema.parse('1000000000000000000000')).toBe(10n ** 21n);
  });

  test('rejects a negative or non-decimal value', () => {
    expect(uintSchema.safeParse('-1').success).toBe(false);
    expect(uintSchema.safeParse('0x10').success).toBe(false);
  });
});

describe('networkSchema', () => {
  test('defaults isTestnet to false and accepts an undeployed receiver', () => {
    expect(networkSchema.parse({chainName: 'ethereum-mainnet', receiver: ''})).toEqual({
      chainName: 'ethereum-mainnet',
      isTestnet: false,
      receiver: '',
    });
  });

  test('rejects an invalid receiver', () => {
    expect(networkSchema.safeParse({chainName: 'ethereum-mainnet', receiver: '0x12'}).success).toBe(
      false,
    );
  });
});

describe('createConfigSchema', () => {
  test('parses the base config', () => {
    const config = configSchema.parse({
      schedule: '0 */10 * * * *',
      evms: [{chainName: 'ethereum-mainnet', receiver: LOWER}],
    });
    expect(config.evms[0].receiver).toBe(CHECKSUMMED);
  });

  test('takes an extended network schema', () => {
    const schema = createConfigSchema(networkSchema.extend({executors: z.array(addressSchema)}));
    const config = schema.parse({
      schedule: '0 * * * *',
      evms: [{chainName: 'avalanche-mainnet', receiver: '', executors: [LOWER]}],
    });
    expect(config.evms[0].executors).toEqual([CHECKSUMMED]);
  });
});
