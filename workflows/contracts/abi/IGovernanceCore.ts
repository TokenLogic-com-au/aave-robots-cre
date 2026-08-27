export const IGovernanceCore = [
  {
    name: 'getProposal',
    type: 'function',
    stateMutability: 'view',
    inputs: [{name: 'proposalId', type: 'uint256'}],
    outputs: [
      {
        name: '',
        type: 'tuple',
        components: [
          {name: 'state', type: 'uint8'},
          {name: 'accessLevel', type: 'uint8'},
          {name: 'creationTime', type: 'uint40'},
          {name: 'votingDuration', type: 'uint24'},
          {name: 'votingActivationTime', type: 'uint40'},
          {name: 'queuingTime', type: 'uint40'},
          {name: 'cancelTimestamp', type: 'uint40'},
          {name: 'creator', type: 'address'},
          {name: 'votingPortal', type: 'address'},
          {name: 'snapshotBlockHash', type: 'bytes32'},
          {name: 'ipfsHash', type: 'bytes32'},
          {name: 'forVotes', type: 'uint128'},
          {name: 'againstVotes', type: 'uint128'},
          {name: 'cancellationFee', type: 'uint256'},
          {
            name: 'payloads',
            type: 'tuple[]',
            components: [
              {name: 'chain', type: 'uint256'},
              {name: 'accessLevel', type: 'uint8'},
              {name: 'payloadsController', type: 'address'},
              {name: 'payloadId', type: 'uint40'},
            ],
          },
        ],
      },
    ],
  },
] as const;
