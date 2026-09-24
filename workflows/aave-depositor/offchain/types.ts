import {z} from 'zod';
import {getAddress, isAddress, type Address} from 'viem';

export {type EvmClient} from '../../shared/offchain/checkUpkeep';

export const BPS = 10_000n;

// Config addresses are typed by hand and viem checks EIP-55 casing strictly when
// encoding, so normalize on parse.
const address = z
  .string()
  .refine((a) => isAddress(a, {strict: false}), 'invalid address')
  .transform((a): Address => getAddress(a.toLowerCase()));
const uint = z.string().regex(/^\d+$/).transform(BigInt);

export const configSchema = z
  .object({
    schedule: z.string(),
    chainName: z.string(),
    isTestnet: z.boolean().default(false),
    // Empty until the receiver is deployed; the workflow registers no trigger meanwhile.
    receiver: address.or(z.literal('')),
    dataProviderV3: address,
    collector: address,
    priceOracle: address,
    corePoolV3: address,
    primePoolV3: address.optional(),
    dataProviderV2: address.optional(),
    corePoolV2: address.optional(),
    depositMinUsd: uint,
    migrationMinUsd: uint,
    migrationBps: uint.refine((b) => b <= BPS, 'migrationBps above 100%'),
    ignoredTokens: z.array(address).default([]),
    primeTokens: z.array(address).default([]),
  })
  .refine((c) => (c.dataProviderV2 === undefined) === (c.corePoolV2 === undefined), {
    message: 'dataProviderV2 and corePoolV2 must be set together',
  });
export type Config = z.infer<typeof configSchema>;

export type Result<T> = {ok: true; value: T} | {ok: false; error: string};
