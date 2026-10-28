import {getAddress, isAddress, type Address} from 'viem';
import {z} from 'zod';

// Config addresses are typed by hand and viem checks EIP-55 casing strictly when encoding,
// so normalize on parse. Casing is not checksum-verified.
export const addressSchema = z
  .string()
  .refine((a) => isAddress(a, {strict: false}), 'invalid address')
  .transform((a): Address => getAddress(a.toLowerCase()));

// Decimal string, since JSON numbers lose precision above 2^53.
export const uintSchema = z.string().regex(/^\d+$/).transform(BigInt);

export const networkSchema = z.object({
  chainName: z.string(),
  isTestnet: z.boolean().default(false),
  // Empty until the receiver is deployed; the network registers no trigger meanwhile.
  receiver: addressSchema.or(z.literal('')),
});
export type NetworkConfig = z.infer<typeof networkSchema>;

/// Robots with more per-network fields pass `networkSchema.extend({...})`.
export function createConfigSchema<TNetwork extends z.ZodTypeAny = typeof networkSchema>(
  network: TNetwork = networkSchema as unknown as TNetwork,
) {
  return z.object({
    schedule: z.string(),
    evms: z.array(network),
  });
}

export const configSchema = createConfigSchema();
export type Config = z.infer<typeof configSchema>;
