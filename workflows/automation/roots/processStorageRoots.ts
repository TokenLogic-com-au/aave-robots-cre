import {
  bytesToHex,
  cre,
  encodeCallMsg,
  prepareReportRequest,
  TxStatus,
  type Runtime,
  type EVMLog,
} from '@chainlink/cre-sdk';
import {
  encodeFunctionData,
  decodeFunctionResult,
  encodeAbiParameters,
  parseAbiParameters,
  zeroAddress,
  type Hex,
} from 'viem';
import {type Config} from '../types';
import {type RootsConfig, type VotingNetworkConfig} from './types';
import {IGovernanceCore} from '../../contracts/abi/IGovernanceCore';
import {IDataWarehouse} from '../../contracts/abi/IDataWarehouse';
import {IMailboxCRE} from '../../contracts/abi/IMailboxCRE';
import {prepareBlockRLP, formatToProofRLP} from './proofs';
import {getBlockByHash, getProof} from './rpc';

const STK_AAVE_EXCHANGE_RATE_SLOT: Hex =
  '0x0000000000000000000000000000000000000000000000000000000000000051';

const ETH_RPC_SECRET_ID = 'ETH_RPC_URL';

function getVotingPortal(
  runtime: Runtime<Config>,
  ethEvmClient: InstanceType<typeof cre.capabilities.EVMClient>,
  governanceAddress: Hex,
  proposalId: bigint,
): Hex {
  const calldata = encodeFunctionData({
    abi: IGovernanceCore,
    functionName: 'getProposal',
    args: [proposalId],
  });

  const result = ethEvmClient
    .callContract(runtime, {
      call: encodeCallMsg({from: zeroAddress, to: governanceAddress, data: calldata}),
    })
    .result();

  const proposal = decodeFunctionResult({
    abi: IGovernanceCore,
    functionName: 'getProposal',
    data: bytesToHex(result.data),
  });

  return proposal.votingPortal as Hex;
}

function resolveVotingNetwork(roots: RootsConfig, votingPortal: Hex): VotingNetworkConfig {
  const network = roots.votingNetworks.find(
    (n) => n.votingPortalAddress.toLowerCase() === votingPortal.toLowerCase(),
  );
  if (!network) {
    throw new Error(`Unknown voting portal: ${votingPortal}`);
  }
  return network;
}

function evmClientFor(chainSelectorName: string): InstanceType<typeof cre.capabilities.EVMClient> {
  const selector =
    cre.capabilities.EVMClient.SUPPORTED_CHAIN_SELECTORS[
      chainSelectorName as keyof typeof cre.capabilities.EVMClient.SUPPORTED_CHAIN_SELECTORS
    ];
  return new cre.capabilities.EVMClient(selector);
}

function sendViaMailbox(
  runtime: Runtime<Config>,
  votingEvmClient: InstanceType<typeof cre.capabilities.EVMClient>,
  mailboxAddress: string,
  dataWarehouseAddress: string,
  functionCalldata: Hex,
  chainName: string,
  label: string,
): Hex {
  const mailboxReportData = encodeAbiParameters(parseAbiParameters('address, bytes'), [
    dataWarehouseAddress as Hex,
    functionCalldata,
  ]);

  const onReportCalldata = encodeFunctionData({
    abi: IMailboxCRE,
    functionName: 'onReport',
    args: ['0x', mailboxReportData],
  });

  const gasEstimate = votingEvmClient
    .estimateGas(runtime, {
      msg: encodeCallMsg({from: zeroAddress, to: mailboxAddress as Hex, data: onReportCalldata}),
    })
    .result();
  runtime.log(`[${chainName}] Gas estimate for ${label}: ${gasEstimate.gas.toString()}`);

  const reportResponse = runtime.report(prepareReportRequest(mailboxReportData)).result();
  const writeResult = votingEvmClient
    .writeReport(runtime, {receiver: mailboxAddress, report: reportResponse})
    .result();

  // A mined-but-reverted tx still returns a txHash, so gate on status before trusting it.
  if (writeResult.txStatus !== TxStatus.SUCCESS) {
    throw new Error(
      `[${chainName}] writeReport status=${writeResult.txStatus} err=${writeResult.errorMessage ?? ''} for ${label}`,
    );
  }
  if (!writeResult.txHash || writeResult.txHash.length === 0) {
    throw new Error(`[${chainName}] writeReport returned SUCCESS but empty txHash for ${label}`);
  }

  const txHash = bytesToHex(writeResult.txHash);
  runtime.log(`[${chainName}] ${label} tx: ${txHash}`);
  return txHash;
}

export function processStorageRoots(
  runtime: Runtime<Config>,
  event: EVMLog,
  roots: RootsConfig,
): string {
  const proposalId = BigInt(bytesToHex(event.topics[1]));
  const snapshotBlockHash = bytesToHex(event.topics[2]) as Hex;
  runtime.log(`VotingActivated: proposalId=${proposalId}, snapshotBlockHash=${snapshotBlockHash}`);

  const ethEvmClient = evmClientFor(roots.ethereumChainSelectorName);
  const votingPortal = getVotingPortal(
    runtime,
    ethEvmClient,
    roots.governanceAddress as Hex,
    proposalId,
  );
  const votingNetwork = resolveVotingNetwork(roots, votingPortal);
  runtime.log(
    `Voting portal ${votingPortal} → ${votingNetwork.chainSelectorName}, DataWarehouse ${votingNetwork.dataWarehouseAddress}`,
  );

  const ethRpcUrl = runtime.getSecret({id: ETH_RPC_SECRET_ID, namespace: 'main'}).result().value;
  const confClient = new cre.capabilities.ConfidentialHTTPClient();
  const blockData = getBlockByHash(confClient, runtime, ethRpcUrl, snapshotBlockHash);
  const blockNumber = blockData.number as Hex;
  const blockHeaderRLP = prepareBlockRLP(blockData);
  runtime.log(`Snapshot block ${blockNumber}`);

  // Each account's storage root is registered; stkAAVE also needs its exchange-rate slot.
  const accounts = [
    {label: 'AAVE', address: roots.tokens.aave as Hex, storageKeys: [] as Hex[]},
    {label: 'aAAVE', address: roots.tokens.aAave as Hex, storageKeys: [] as Hex[]},
    {label: 'stkAAVE', address: roots.tokens.stkAave as Hex, storageKeys: [STK_AAVE_EXCHANGE_RATE_SLOT]},
    {label: 'Governance', address: roots.governanceAddress as Hex, storageKeys: [] as Hex[]},
  ];

  const submissions: Array<{calldata: Hex; label: string}> = [];
  let stkStorageProof: Hex[] | undefined;

  for (const account of accounts) {
    const proof = getProof(confClient, runtime, ethRpcUrl, account.address, account.storageKeys, blockNumber);
    submissions.push({
      label: `processStorageRoot(${account.label})`,
      calldata: encodeFunctionData({
        abi: IDataWarehouse,
        functionName: 'processStorageRoot',
        args: [account.address, snapshotBlockHash, blockHeaderRLP, formatToProofRLP(proof.accountProof)],
      }),
    });
    if (account.storageKeys.length > 0) stkStorageProof = proof.storageProof[0].proof;
  }

  if (!stkStorageProof) throw new Error('stkAAVE storage proof missing');
  submissions.push({
    label: 'processStorageSlot(stkAAVE exchangeRate)',
    calldata: encodeFunctionData({
      abi: IDataWarehouse,
      functionName: 'processStorageSlot',
      args: [roots.tokens.stkAave as Hex, snapshotBlockHash, STK_AAVE_EXCHANGE_RATE_SLOT, formatToProofRLP(stkStorageProof)],
    }),
  });
  runtime.log('All proofs fetched and formatted');

  const votingEvmClient = evmClientFor(votingNetwork.chainSelectorName);
  const chainName = votingNetwork.chainSelectorName;
  for (const {calldata, label} of submissions) {
    sendViaMailbox(
      runtime,
      votingEvmClient,
      votingNetwork.mailboxAddress,
      votingNetwork.dataWarehouseAddress,
      calldata,
      chainName,
      label,
    );
  }

  runtime.log(`All storage roots submitted for proposal ${proposalId} on ${chainName}`);
  return `Storage roots submitted for proposal ${proposalId}`;
}
