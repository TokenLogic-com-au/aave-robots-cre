import {z} from 'zod';

import {addressSchema, createConfigSchema, networkSchema} from '../../shared/offchain/config';

export const proofOfReserveNetworkSchema = networkSchema.extend({
  // Proof of Reserve executors, one per Aave pool (e.g. Avalanche v2 + v3).
  executors: z.array(addressSchema),
});
export type NetworkConfig = z.infer<typeof proofOfReserveNetworkSchema>;

export const configSchema = createConfigSchema(proofOfReserveNetworkSchema);
export type Config = z.infer<typeof configSchema>;
