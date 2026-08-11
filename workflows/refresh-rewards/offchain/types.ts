import {z} from 'zod';

// A (stataToken factory, rewards controller) pair. One Aave pool = one pair;
// a chain with several pools (e.g. Ethereum Core + Prime) lists several.
export const poolSchema = z.object({
  factory: z.string(),
  controller: z.string(),
});
export type Pool = z.infer<typeof poolSchema>;

export const networkSchema = z.object({
  chainName: z.string(),
  isTestnet: z.boolean().default(false),
  receiver: z.string(),
  pools: z.array(poolSchema),
});
export type NetworkConfig = z.infer<typeof networkSchema>;

export const configSchema = z.object({
  schedule: z.string(),
  evms: z.array(networkSchema),
});
export type Config = z.infer<typeof configSchema>;
