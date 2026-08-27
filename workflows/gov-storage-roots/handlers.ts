import {cre, handler, logTriggerConfig, type Runtime, type EVMLog} from '@chainlink/cre-sdk';
import {keccak256, toHex, type Hex} from 'viem';
import {type Config} from './types';
import {processStorageRoots} from './processStorageRoots';

// VotingActivated(uint256 indexed proposalId, bytes32 indexed snapshotBlockHash, uint24 votingDuration)
const VOTING_ACTIVATED_SIGNATURE = keccak256(toHex('VotingActivated(uint256,bytes32,uint24)'));

const onVotingActivated = (runtime: Runtime<Config>, event: EVMLog): string => {
  try {
    return processStorageRoots(runtime, event);
  } catch (e) {
    runtime.log(`Error processing storage roots: ${e}`);
    return `Error: ${e}`;
  }
};

export const createHandlers = (config: Config) => {
  const ethChainSelector =
    cre.capabilities.EVMClient.SUPPORTED_CHAIN_SELECTORS[
      config.ethereumChainSelectorName as keyof typeof cre.capabilities.EVMClient.SUPPORTED_CHAIN_SELECTORS
    ];
  const ethEvmClient = new cre.capabilities.EVMClient(ethChainSelector);

  const trigger = ethEvmClient.logTrigger(
    logTriggerConfig({
      addresses: [config.governanceAddress as Hex],
      topics: [[VOTING_ACTIVATED_SIGNATURE]],
      confidence: 'LATEST',
    }),
  );

  return [handler(trigger, onVotingActivated)];
};
