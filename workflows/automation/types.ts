import {z} from 'zod';
import {addressSchema} from './address';
import {rootsConfigSchema} from './roots/types';

export const automationSchema = z.object({
  address: addressSchema,
  checkData: z.string(),
  name: z.string().optional(),
});
export type AutomationConfig = z.infer<typeof automationSchema>;

export const networkSchema = z.object({
  chainName: z.string(),
  mailboxAddress: addressSchema,
  automations: z.array(automationSchema),
});
export type NetworkConfig = z.infer<typeof networkSchema>;

export const configSchema = z.object({
  schedule: z.string(),
  evms: z.array(networkSchema),
  // Optional: when present, layers the governance storage-roots log-trigger handler
  // onto this workflow (see roots/). Only configs that set it get the extra handler.
  roots: rootsConfigSchema.optional(),
});
export type Config = z.infer<typeof configSchema>;
