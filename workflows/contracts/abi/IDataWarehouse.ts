export const IDataWarehouse = [
  {
    name: 'processStorageRoot',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      {name: 'account', type: 'address'},
      {name: 'blockHash', type: 'bytes32'},
      {name: 'blockHeaderRLP', type: 'bytes'},
      {name: 'accountStateProofRLP', type: 'bytes'},
    ],
    outputs: [{name: '', type: 'bytes32'}],
  },
  {
    name: 'processStorageSlot',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      {name: 'account', type: 'address'},
      {name: 'blockHash', type: 'bytes32'},
      {name: 'slot', type: 'bytes32'},
      {name: 'storageProof', type: 'bytes'},
    ],
    outputs: [],
  },
] as const;
