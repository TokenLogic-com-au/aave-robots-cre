import {toRlp, fromRlp, type Hex} from 'viem';

// RLP encodes integers minimally: zero and any leading zeros collapse to '0x'.
function normalizeQuantity(hex: string): Hex {
  if (!hex || hex === '0x' || hex === '0x0' || hex === '0x00') return '0x';
  const stripped = hex.replace(/^0x0+/, '0x');
  return (stripped === '0x' ? '0x' : stripped) as Hex;
}

export function prepareBlockRLP(rawBlock: Record<string, string>): Hex {
  const rawData: Hex[] = [
    rawBlock.parentHash as Hex,
    rawBlock.sha3Uncles as Hex,
    rawBlock.miner as Hex,
    rawBlock.stateRoot as Hex,
    rawBlock.transactionsRoot as Hex,
    rawBlock.receiptsRoot as Hex,
    rawBlock.logsBloom as Hex,
    '0x', // difficulty (0 post-merge)
    normalizeQuantity(rawBlock.number),
    normalizeQuantity(rawBlock.gasLimit),
    normalizeQuantity(rawBlock.gasUsed),
    normalizeQuantity(rawBlock.timestamp),
    rawBlock.extraData as Hex,
    rawBlock.mixHash as Hex,
    rawBlock.nonce as Hex,
  ];

  // Trailing fields exist only from the fork that added them.
  if (rawBlock.baseFeePerGas) rawData.push(normalizeQuantity(rawBlock.baseFeePerGas)); // London
  if (rawBlock.withdrawalsRoot) rawData.push(rawBlock.withdrawalsRoot as Hex); // Shanghai
  if (rawBlock.blobGasUsed !== undefined) {
    // Cancun
    rawData.push(normalizeQuantity(rawBlock.blobGasUsed));
    rawData.push(normalizeQuantity(rawBlock.excessBlobGas));
  }
  if (rawBlock.parentBeaconBlockRoot) rawData.push(rawBlock.parentBeaconBlockRoot as Hex); // EIP-4788
  if (rawBlock.requestsHash) rawData.push(rawBlock.requestsHash as Hex); // Pectra

  return toRlp(rawData);
}

// getProof nodes are already RLP-encoded; re-wrap the array as one RLP list.
export function formatToProofRLP(rawData: Hex[]): Hex {
  return toRlp(rawData.map((d) => fromRlp(d, 'hex')));
}
