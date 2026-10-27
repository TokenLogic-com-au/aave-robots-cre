import {z} from 'zod';

import {
  addressSchema,
  createConfigSchema,
  networkSchema,
  uintSchema,
} from '../../shared/offchain/config';

export const gsmNetworkSchema = networkSchema.extend({
  gsms: z.array(addressSchema).nonempty(),
  // GHO wei; a GSM below this is left to accrue.
  minFees: uintSchema,
});
export type NetworkConfig = z.infer<typeof gsmNetworkSchema>;

export const configSchema = createConfigSchema(gsmNetworkSchema);
export type Config = z.infer<typeof configSchema>;
