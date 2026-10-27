import {z} from 'zod';

import {addressSchema, networkSchema, uintSchema} from '../../shared/offchain/config';

export const BPS = 10_000n;

// One workflow per chain, so the network fields sit at the top level.
export const configSchema = networkSchema
  .extend({
    schedule: z.string(),
    dataProviderV3: addressSchema,
    collector: addressSchema,
    priceOracle: addressSchema,
    corePoolV3: addressSchema,
    primePoolV3: addressSchema.optional(),
    dataProviderV2: addressSchema.optional(),
    corePoolV2: addressSchema.optional(),
    depositMinUsd: uintSchema,
    migrationMinUsd: uintSchema,
    migrationBps: uintSchema.refine((b) => b <= BPS, 'migrationBps above 100%'),
    ignoredTokens: z.array(addressSchema).default([]),
    primeTokens: z.array(addressSchema).default([]),
  })
  .refine((c) => (c.dataProviderV2 === undefined) === (c.corePoolV2 === undefined), {
    message: 'dataProviderV2 and corePoolV2 must be set together',
  });
export type Config = z.infer<typeof configSchema>;

export type Result<T> = {ok: true; value: T} | {ok: false; error: string};
