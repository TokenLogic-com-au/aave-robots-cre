import {z} from 'zod';

export const automationSchema = z.object({
  address: z.string(),
  checkData: z.string(),
  name: z.string().optional(),
});
export type AutomationConfig = z.infer<typeof automationSchema>;

export const networkSchema = z.object({
  chainName: z.string(),
  mailboxAddress: z.string(),
  automations: z.array(automationSchema),
});
export type NetworkConfig = z.infer<typeof networkSchema>;

export const configSchema = z.object({
  schedule: z.string(),
  evms: z.array(networkSchema),
});
export type Config = z.infer<typeof configSchema>;
