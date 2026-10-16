import {z} from 'zod';
import {addressSchema} from '../address';

export const votingNetworkSchema = z.object({
  votingPortalAddress: addressSchema,
  chainSelectorName: z.string(),
  dataWarehouseAddress: addressSchema,
  mailboxAddress: addressSchema,
});
export type VotingNetworkConfig = z.infer<typeof votingNetworkSchema>;

export const rootsConfigSchema = z.object({
  ethereumChainSelectorName: z.string(),
  governanceAddress: addressSchema,
  tokens: z.object({
    aave: addressSchema,
    aAave: addressSchema,
    stkAave: addressSchema,
  }),
  votingNetworks: z.array(votingNetworkSchema),
});
export type RootsConfig = z.infer<typeof rootsConfigSchema>;
