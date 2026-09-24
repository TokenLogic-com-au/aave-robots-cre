import {z} from 'zod';
import {getAddress, isAddress, type Address} from 'viem';

// Config addresses are typed by hand and viem checks EIP-55 casing strictly when
// encoding, so normalize on parse. Casing is not checksum-verified.
const address = z
  .string()
  .refine((a) => isAddress(a, {strict: false}), 'invalid address')
  .transform((a): Address => getAddress(a.toLowerCase()));
const uint = z.string().regex(/^\d+$/).transform(BigInt);

export const networkSchema = z.object({
  chainName: z.string(),
  isTestnet: z.boolean().default(false),
  // Empty until the receiver is deployed; the network registers no trigger meanwhile.
  receiver: address.or(z.literal('')),
  gsms: z.array(address).nonempty(),
  // GHO wei; a GSM below this is left to accrue.
  minFees: uint,
});
export type NetworkConfig = z.infer<typeof networkSchema>;

export const configSchema = z.object({
  schedule: z.string(),
  evms: z.array(networkSchema),
});
export type Config = z.infer<typeof configSchema>;
