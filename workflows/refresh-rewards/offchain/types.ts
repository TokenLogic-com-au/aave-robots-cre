import {z} from 'zod';

import {addressSchema, createConfigSchema, networkSchema} from '../../shared/offchain/config';

export const refreshRewardsNetworkSchema = networkSchema.extend({
  // stataToken factories, one per Aave pool (e.g. Ethereum Core + Lido).
  factories: z.array(addressSchema),
});
export type NetworkConfig = z.infer<typeof refreshRewardsNetworkSchema>;

export const configSchema = createConfigSchema(refreshRewardsNetworkSchema);
export type Config = z.infer<typeof configSchema>;
