import {z} from 'zod';

export const networkSchema = z.object({
  chainName: z.string(),
  isTestnet: z.boolean().default(false),
  receiver: z.string(),
  // stataToken factories, one per Aave pool (e.g. Ethereum Core + Lido).
  factories: z.array(z.string()),
});
export type NetworkConfig = z.infer<typeof networkSchema>;

export const configSchema = z.object({
  schedule: z.string(),
  evms: z.array(networkSchema),
});
export type Config = z.infer<typeof configSchema>;
