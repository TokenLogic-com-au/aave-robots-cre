// AaveDepositorReceiver, the subset the workflow reads and writes.
export const IAaveDepositorReceiver = [
  {
    inputs: [],
    name: 'FORWARDER',
    outputs: [{internalType: 'address', name: '', type: 'address'}],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [],
    name: 'expectedWorkflowId',
    outputs: [{internalType: 'bytes32', name: '', type: 'bytes32'}],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [{internalType: 'bytes', name: 'checkData', type: 'bytes'}],
    name: 'checkUpkeep',
    outputs: [
      {internalType: 'bool', name: 'upkeepNeeded', type: 'bool'},
      {internalType: 'bytes', name: 'performData', type: 'bytes'},
    ],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [
      {internalType: 'bytes', name: 'metadata', type: 'bytes'},
      {internalType: 'bytes', name: 'report', type: 'bytes'},
    ],
    name: 'onReport',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function',
  },
] as const;
