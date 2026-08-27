import {describe, expect, test} from 'bun:test';
import {keccak256, toRlp, fromRlp, type Hex} from 'viem';
import {prepareBlockRLP, formatToProofRLP} from './proofs';

// Real post-Pectra Ethereum mainnet block (21 header fields). The RLP encoding
// produced by prepareBlockRLP must hash back to this exact block hash — that is
// what the DataWarehouse verifies on-chain against `blockHash`.
const BLOCK_HASH: Hex = '0xfa289779df7a1833356e876b96c82c85aba6e1c5715912678ce1c33445e30038';
const BLOCK: Record<string, string> = {
  parentHash: '0xa55ac493e43d5684680b6efef05a8d0336bd6347ce6c76d0f2d3922b57864b21',
  sha3Uncles: '0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347',
  miner: '0xd4e96ef8eee8678dbff4d535e033ed1a4f7605b7',
  stateRoot: '0x623a537d5993851ade7c35ff6e854a028c647b1158d59e9fd1736f14ce7c1bff',
  transactionsRoot: '0x0c52e8561473db07949bf7d41a6fd3fec711b20906eaecd24bedd65734eeb511',
  receiptsRoot: '0x4f9e55a214408b2e343d098fd44d87ce07e70dacd1ad38b1a6e064e8df8878bf',
  logsBloom:
    '0xc1f5acc9c1861386b8a1c02dc4c00d83190014610c22f1cc628f70994ad088a5863446222ada093033157780c824718fc335955cbe837409f8b071c125ecc683930a28520454423959bd840d8567a8309c4c78899d2531a43352303e1331484374a9401eba8305b184456c9690190b65e00a61b2ad9421eb8680451dd4ae3640881850e84185c99e5851203ac302096b54f844e1ef002c0e19250952e134bebda6040423b5047022535c4eb2f83a3cc004c531552053a004cf144869110004d32221981f01a60402a2ab8c5b42c32844c4e48d6221699d3035ab3011a21025407a30ac0c8721618144744972b1a71dea47640488273607401781892c00656595',
  number: '0x18a219e',
  gasLimit: '0x3938700',
  gasUsed: '0xdd7e3a',
  timestamp: '0x6a8d1873',
  extraData: '0x626573752032362e352e302d524332',
  mixHash: '0xb5ef45d9907952a60bdc654227bb4c78fb6580adbceb96b5d301192c9ed5eac0',
  nonce: '0x0000000000000000',
  baseFeePerGas: '0x551e0b4',
  withdrawalsRoot: '0xb6333e4e8a9e34ef685d9d86d7d5ec6686a9b097ab3395e4211b8a693aafb671',
  blobGasUsed: '0x60000',
  excessBlobGas: '0xada3823',
  parentBeaconBlockRoot: '0x306eb33df9e947109ef965896a4906a70b6bb60c57d7a7155a1bb85dd514baee',
  requestsHash: '0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
};

describe('prepareBlockRLP', () => {
  test('re-encodes a post-Pectra header that hashes back to the block hash', () => {
    const headerRLP = prepareBlockRLP(BLOCK);
    expect(keccak256(headerRLP)).toBe(BLOCK_HASH);
  });

  test('drops trailing fields for a pre-London header (no baseFeePerGas)', () => {
    const {baseFeePerGas, withdrawalsRoot, blobGasUsed, excessBlobGas, parentBeaconBlockRoot, requestsHash, ...preLondon} =
      BLOCK;
    const headerRLP = prepareBlockRLP(preLondon);
    // 15 legacy header fields, no post-London extensions.
    expect(fromRlp(headerRLP, 'hex').length).toBe(15);
  });
});

describe('formatToProofRLP', () => {
  test('wraps an array of RLP nodes into a single RLP list (round-trips)', () => {
    // Two arbitrary already-RLP-encoded nodes, as eth_getProof returns them.
    const nodes: Hex[] = [toRlp(['0x01', '0x02']), toRlp(['0xdead', '0xbeef'])];
    const wrapped = formatToProofRLP(nodes);
    const decoded = fromRlp(wrapped, 'hex') as Hex[];
    expect(decoded.length).toBe(2);
    expect(toRlp(decoded[0] as any)).toBe(nodes[0]);
    expect(toRlp(decoded[1] as any)).toBe(nodes[1]);
  });
});
