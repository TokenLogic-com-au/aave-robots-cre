import {describe, expect} from 'bun:test';
import {TxStatus, getNetwork} from '@chainlink/cre-sdk';
import {EvmMock, newTestRuntime, test} from '@chainlink/cre-sdk/test';
import {
  encodeAbiParameters,
  encodeEventTopics,
  hexToBytes,
  parseAbiParameters,
  type Hex,
} from 'viem';

import {IHubABI} from '../../shared/offchain/abi/IHub';
import {
  dispatchCallContract,
  mockLog,
  mockReceipt,
  type HubAssetPair,
} from '../../shared/offchain/testing/mocks';
import {AaveV4Ethereum, hubsFor} from '../../shared/offchain/addresses';
import {createTargetHandler, initWorkflow} from './workflow';

const CHAIN_NAME = 'ethereum-mainnet';
const CHAIN_SELECTOR = getNetwork({
  chainFamily: 'evm',
  chainSelectorName: CHAIN_NAME,
  isTestnet: false,
})!.chainSelector.selector;

const MINTER = '0x1111111111111111111111111111111111111111' as Hex;
const HUB = '0x2222222222222222222222222222222222222222' as Hex;
const FEE_RECEIVER = '0x3333333333333333333333333333333333333333' as Hex;
const TX_HASH = ('0xab' + 'cd'.repeat(31)) as Hex;

const TARGET = {minter: MINTER, hub: HUB};
const NETWORK = {chainName: CHAIN_NAME, isTestnet: false, minter: MINTER};
const CONFIG = {schedule: '* * * * *', evms: [NETWORK]};

function makeRuntime() {
  const runtime = newTestRuntime();
  (runtime as unknown as {config: typeof CONFIG}).config = CONFIG;
  return runtime;
}

function mintFeeSharesLog(assetId: bigint, shares: bigint, assets: bigint) {
  const topics = encodeEventTopics({
    abi: IHubABI,
    eventName: 'MintFeeShares',
    args: {assetId, feeReceiver: FEE_RECEIVER},
  }) as readonly Hex[];
  const data = encodeAbiParameters(parseAbiParameters('uint256, uint256'), [shares, assets]);
  return mockLog({address: HUB, topics, data});
}

const handle = createTargetHandler(NETWORK, TARGET);

describe('fee-shares-minter workflow', () => {
  test('returns evaluated=0 when assetCount is 0', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = dispatchCallContract({getAssetCount: () => 0n});

    const runtime = makeRuntime();
    expect(handle(runtime as never)).toBe('evaluated 0 assets, minted 0, skipped 0');
  });

  test('skips submission when checkUpkeep returns empty mintable subset', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = dispatchCallContract({
      getAssetCount: () => 3n,
      checkUpkeep: () => ({upkeepNeeded: false, mintable: []}),
    });

    const runtime = makeRuntime();
    expect(handle(runtime as never)).toBe('evaluated 3 assets, minted 0, skipped 3');
  });

  test('skips submission when checkUpkeep reverts', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    let firstCall = true;
    evmMock.callContract = (req: never) => {
      if (firstCall) {
        firstCall = false;
        return dispatchCallContract({getAssetCount: () => 2n})(
          req as Parameters<ReturnType<typeof dispatchCallContract>>[0],
        );
      }
      throw new Error('checkUpkeep reverted');
    };

    const runtime = makeRuntime();
    expect(handle(runtime as never)).toBe('evaluated 2 assets, minted 0, skipped 2');
    expect(
      runtime.getLogs().find((l) => l.includes('checkUpkeep reverted — skipping')),
    ).toBeDefined();
  });

  test('counts submission-skipped when estimateGas reverts', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = dispatchCallContract({
      getAssetCount: () => 2n,
      checkUpkeep: (pairs) => ({upkeepNeeded: true, mintable: pairs}),
    });
    evmMock.estimateGas = () => {
      throw new Error('reverted');
    };

    const runtime = makeRuntime();
    expect(handle(runtime as never)).toBe('evaluated 2 assets, minted 0, skipped 2');
  });

  test('submits one batched tx and parses MintFeeShares for every mintable asset', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = dispatchCallContract({
      getAssetCount: () => 2n,
      checkUpkeep: (pairs) => ({upkeepNeeded: true, mintable: pairs}),
    });
    evmMock.estimateGas = () => ({gas: 100_000n});
    evmMock.writeReport = () => ({txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)});
    evmMock.getTransactionReceipt = () => ({
      receipt: mockReceipt({
        txHash: TX_HASH,
        logs: [mintFeeSharesLog(0n, 100n, 200n), mintFeeSharesLog(1n, 101n, 201n)],
      }),
    });

    const runtime = makeRuntime();
    expect(handle(runtime as never)).toBe('evaluated 2 assets, minted 2, skipped 0');

    const logs = runtime.getLogs();
    expect(logs.find((l) => l.includes('asset=0') && l.includes('shares=100'))).toBeDefined();
    expect(logs.find((l) => l.includes('asset=1') && l.includes('shares=101'))).toBeDefined();
    expect(logs.find((l) => l.includes('mintable=2/2'))).toBeDefined();
  });

  test('mintable subset filters out unmintable asset, mints the rest in one tx', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = dispatchCallContract({
      getAssetCount: () => 3n,
      checkUpkeep: (pairs: HubAssetPair[]) => ({
        upkeepNeeded: true,
        mintable: pairs.filter((p) => p.assetId !== 1n),
      }),
    });
    evmMock.estimateGas = () => ({gas: 100_000n});
    evmMock.writeReport = () => ({txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)});
    evmMock.getTransactionReceipt = () => ({
      receipt: mockReceipt({
        txHash: TX_HASH,
        logs: [mintFeeSharesLog(0n, 1n, 1n), mintFeeSharesLog(2n, 1n, 1n)],
      }),
    });

    const runtime = makeRuntime();
    expect(handle(runtime as never)).toBe('evaluated 3 assets, minted 2, skipped 1');
    expect(runtime.getLogs().find((l) => l.includes('mintable=2/3'))).toBeDefined();
  });

  test('logs "no MintFeeShares" when expected event is missing from receipt', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = dispatchCallContract({
      getAssetCount: () => 1n,
      checkUpkeep: (pairs) => ({upkeepNeeded: true, mintable: pairs}),
    });
    evmMock.estimateGas = () => ({gas: 100_000n});
    evmMock.writeReport = () => ({txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)});
    evmMock.getTransactionReceipt = () => ({receipt: mockReceipt({txHash: TX_HASH})});

    const runtime = makeRuntime();
    expect(handle(runtime as never)).toBe('evaluated 1 assets, minted 0, skipped 1');
    expect(runtime.getLogs().find((l) => l.includes('no MintFeeShares event found'))).toBeDefined();
  });
});

describe('addresses.hubsFor', () => {
  test('returns the three Ethereum v4 hubs from the address book', () => {
    const hubs = hubsFor('ethereum-mainnet');
    expect(hubs).toEqual([
      AaveV4Ethereum.HUBS.CORE_HUB,
      AaveV4Ethereum.HUBS.PLUS_HUB,
      AaveV4Ethereum.HUBS.PRIME_HUB,
    ] as readonly Hex[]);
  });

  test('returns empty array for unknown chain', () => {
    expect(hubsFor('made-up-chain')).toEqual([]);
  });
});

describe('initWorkflow', () => {
  test('creates one handler per hub for the configured chain', () => {
    const handlers = initWorkflow({
      schedule: '* * * * *',
      evms: [{chainName: CHAIN_NAME, isTestnet: false, minter: MINTER}],
    });
    expect(handlers.length).toBe(hubsFor(CHAIN_NAME).length);
  });

  test('skips networks with empty minter', () => {
    const handlers = initWorkflow({
      schedule: '* * * * *',
      evms: [{chainName: CHAIN_NAME, isTestnet: false, minter: ''}],
    });
    expect(handlers.length).toBe(0);
  });

  test('produces no handlers for an unknown chain', () => {
    const handlers = initWorkflow({
      schedule: '* * * * *',
      evms: [{chainName: 'made-up-chain', isTestnet: false, minter: MINTER}],
    });
    expect(handlers.length).toBe(0);
  });
});
