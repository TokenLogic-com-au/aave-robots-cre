import {describe, expect} from 'bun:test';
import {EvmMock, newTestRuntime, test} from '@chainlink/cre-sdk/test';
import {encodeAbiParameters, encodeEventTopics, parseAbiParameters, type Hex} from 'viem';

import {IHubABI} from '../abi/IHub';
import {findEvents} from '../events';
import {getEvmClient} from '../network';
import {chainSelectorOf, mockLog, mockReceipt, type MockLog} from '../testing/mocks';

const CHAIN_NAME = 'ethereum-mainnet';
const HUB = '0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9' as Hex;
const OTHER = '0x1111111111111111111111111111111111111111' as Hex;
const FEE_RECEIVER = '0x2222222222222222222222222222222222222222' as Hex;
const TX_HASH = ('0xab' + 'cd'.repeat(31)) as Hex;

function mintFeeShares(emitter: Hex, assetId: bigint): MockLog {
  const topics = encodeEventTopics({
    abi: IHubABI,
    eventName: 'MintFeeShares',
    args: {assetId, feeReceiver: FEE_RECEIVER},
  }) as readonly Hex[];
  const data = encodeAbiParameters(parseAbiParameters('uint256, uint256'), [10n, 20n]);
  return mockLog({address: emitter, topics, data});
}

function find(logs: MockLog[] | null) {
  const evmMock = EvmMock.testInstance(chainSelectorOf(CHAIN_NAME));
  evmMock.getTransactionReceipt = () =>
    logs === null ? {} : {receipt: mockReceipt({txHash: TX_HASH, logs})};
  const evmClient = getEvmClient({chainName: CHAIN_NAME})!;
  return findEvents(newTestRuntime(), evmClient, TX_HASH, IHubABI, 'MintFeeShares', [HUB]);
}

describe('findEvents', () => {
  test('decodes the events of the emitters, keeping their casing', () => {
    expect(find([mintFeeShares(HUB.toLowerCase() as Hex, 1n)])).toEqual([
      {emitter: HUB, args: {assetId: 1n, feeReceiver: FEE_RECEIVER, shares: 10n, assets: 20n}},
    ]);
  });

  test('ignores other emitters', () => {
    expect(find([mintFeeShares(OTHER, 1n)])).toEqual([]);
  });

  test('ignores other events of the emitter', () => {
    const log = mintFeeShares(HUB, 1n);
    log.topics[0] = new Uint8Array(32);
    expect(find([log])).toEqual([]);
  });

  test('returns nothing without a receipt', () => {
    expect(find(null)).toEqual([]);
  });
});
