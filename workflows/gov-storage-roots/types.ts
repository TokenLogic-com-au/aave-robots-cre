import {z} from 'zod';

export const votingNetworkSchema = z.object({
  votingPortalAddress: z.string(),
  chainSelectorName: z.string(),
  dataWarehouseAddress: z.string(),
  mailboxAddress: z.string(),
});
export type VotingNetworkConfig = z.infer<typeof votingNetworkSchema>;

export const configSchema = z.object({
  ethereumChainSelectorName: z.string(),
  governanceAddress: z.string(),
  tokens: z.object({
    aave: z.string(),
    aAave: z.string(),
    stkAave: z.string(),
  }),
  votingNetworks: z.array(votingNetworkSchema),
});
export type Config = z.infer<typeof configSchema>;
