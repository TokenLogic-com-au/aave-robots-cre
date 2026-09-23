import {z} from 'zod';
import {getAddress} from 'viem';

// Config addresses are typed by hand and viem checks EIP-55 casing strictly when
// encoding, so normalize on parse. An empty string is kept so unset receivers skip.
const address = z.string().transform((a) => (a ? getAddress(a.toLowerCase()) : a));

export const networkSchema = z.object({
  chainName: z.string(),
  isTestnet: z.boolean().default(false),
  receiver: address,
  gsms: z.array(address),
});
export type NetworkConfig = z.infer<typeof networkSchema>;

export const configSchema = z.object({
  schedule: z.string(),
  evms: z.array(networkSchema),
});
export type Config = z.infer<typeof configSchema>;
