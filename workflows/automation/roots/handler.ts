import {cre, handler, logTriggerConfig, type Runtime, type EVMLog} from '@chainlink/cre-sdk';
import {keccak256, toHex, type Hex} from 'viem';
import {type Config} from '../types';
import {type RootsConfig} from './types';
import {processStorageRoots} from './processStorageRoots';

// VotingActivated(uint256 indexed proposalId, bytes32 indexed snapshotBlockHash, uint24 votingDuration)
const VOTING_ACTIVATED_SIGNATURE = keccak256(toHex('VotingActivated(uint256,bytes32,uint24)'));

// One extra log-triggered handler, layered onto the automation engine when the config
// carries a `roots` section. It submits Ethereum storage proofs to the voting chain's
// DataWarehouse (via MailboxCRE) whenever a governance proposal's voting activates.
export const createRootsHandler = (roots: RootsConfig) => {
  const ethChainSelector =
    cre.capabilities.EVMClient.SUPPORTED_CHAIN_SELECTORS[
      roots.ethereumChainSelectorName as keyof typeof cre.capabilities.EVMClient.SUPPORTED_CHAIN_SELECTORS
    ];
  const ethEvmClient = new cre.capabilities.EVMClient(ethChainSelector);

  const trigger = ethEvmClient.logTrigger(
    logTriggerConfig({
      addresses: [roots.governanceAddress as Hex],
      topics: [[VOTING_ACTIVATED_SIGNATURE]],
      confidence: 'LATEST',
    }),
  );

  const onVotingActivated = (runtime: Runtime<Config>, event: EVMLog): string => {
    try {
      return processStorageRoots(runtime, event, roots);
    } catch (e) {
      runtime.log(`Error processing storage roots: ${e}`);
      return `Error: ${e}`;
    }
  };

  return handler(trigger, onVotingActivated);
};
