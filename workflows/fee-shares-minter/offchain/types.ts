import {z} from 'zod';

export const networkSchema = z.object({
  chainName: z.string(),
  isTestnet: z.boolean().default(false),
  minter: z.string(),
});
export type NetworkConfig = z.infer<typeof networkSchema>;

export const configSchema = z.object({
  schedule: z.string(),
  evms: z.array(networkSchema),
});
export type Config = z.infer<typeof configSchema>;

export type Target = {minter: string; hub: string};
