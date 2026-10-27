import {describe, expect} from 'bun:test';
import {TxStatus, protoBigIntToBigint} from '@chainlink/cre-sdk';
import {EVM_PB} from '@chainlink/cre-sdk/pb';
import {EvmMock, newTestRuntime, test} from '@chainlink/cre-sdk/test';
import {bytesToHex, hexToBytes, type Hex} from 'viem';

import {
  chainSelectorOf,
  checkUpkeepMock,
  type CallContractInput,
} from '../../shared/offchain/testing/mocks';
import {DEFICIT_CREATED, createReceiverHandler, initWorkflow} from './workflow';

const CHAIN_NAME = 'ethereum-mainnet';
const CHAIN_SELECTOR = chainSelectorOf(CHAIN_NAME);

const RECEIVER = '0x1111111111111111111111111111111111111111' as Hex;
const TX_HASH = ('0xab' + 'cd'.repeat(31)) as Hex;
// The workflow treats performData as opaque (it only signs it), so any non-empty payload works.
const PERFORM_DATA = '0xdeadbeef' as Hex;

const NETWORK = {chainName: CHAIN_NAME, isTestnet: false, receiver: RECEIVER};

const handle = createReceiverHandler(NETWORK);

describe('slashing workflow', () => {
  test('returns "No slash needed" when checkUpkeep is false', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(false);

    expect(handle(newTestRuntime() as never)).toBe('No slash needed');
  });

  test('returns "submit skipped" when estimateGas reverts', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true, PERFORM_DATA);
    evmMock.estimateGas = () => {
      throw new Error('reverted');
    };

    expect(handle(newTestRuntime() as never)).toBe('submit skipped');
  });

  test('submits the report and returns the tx hash on success', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true, PERFORM_DATA);
    evmMock.estimateGas = () => ({gas: 100_000n});
    evmMock.writeReport = () => ({txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)});

    expect(handle(newTestRuntime() as never)).toBe(`slashed, tx=${TX_HASH}`);
  });

  test('the DeficitCreated handler reads checkUpkeep at the log block and logs the tx', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    let readAt: bigint | undefined;
    evmMock.callContract = (req: CallContractInput & {blockNumber?: never}) => {
      readAt = req.blockNumber ? protoBigIntToBigint(req.blockNumber) : undefined;
      return checkUpkeepMock(true, PERFORM_DATA)(req);
    };
    evmMock.estimateGas = () => ({gas: 100_000n});
    evmMock.writeReport = () => ({txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)});
    const logTxHash = ('0x' + '11'.repeat(32)) as Hex;

    const runtime = newTestRuntime();
    const logHandle = createReceiverHandler(NETWORK, 'DeficitCreated');
    expect(
      logHandle(runtime as never, {txHash: hexToBytes(logTxHash), blockNumber: 25_930_933n}),
    ).toBe(`slashed, tx=${TX_HASH}`);
    expect(readAt).toBe(25_930_933n);
    expect(runtime.getLogs().find((l) => l.includes(`DeficitCreated ${logTxHash}`))).toBeDefined();
  });

  test('the cron handler reads checkUpkeep at the latest block', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    let blockNumberSet = true;
    evmMock.callContract = (req: CallContractInput & {blockNumber?: unknown}) => {
      blockNumberSet = req.blockNumber !== undefined;
      return checkUpkeepMock(false)(req);
    };

    handle(newTestRuntime() as never);
    expect(blockNumberSet).toBe(false);
  });
});

describe('initWorkflow', () => {
  test('DEFICIT_CREATED is the Pool DeficitCreated event topic', () => {
    // keccak256('DeficitCreated(address,address,uint256)'), as emitted by IPool.
    expect(DEFICIT_CREATED).toBe(
      '0x2bccfb3fad376d59d7accf970515eb77b2f27b082c90ed0fb15583dd5a942699',
    );
  });

  // `--trigger-index` in package.json and the README rely on cron = 0, log = 1.
  test('creates the cron (index 0) and the DeficitCreated log trigger (index 1)', () => {
    const [cronEntry, logEntry, ...rest] = initWorkflow({
      schedule: '0 * * * *',
      evms: [NETWORK],
    }) as unknown as {trigger: {config: Record<string, unknown>}}[];
    expect(rest.length).toBe(0);
    expect(cronEntry.trigger.config.schedule).toBe('0 * * * *');

    const filter = logEntry.trigger.config as {
      addresses: Uint8Array[];
      topics: {values: Uint8Array[]}[];
      confidence: number;
    };
    // Aave v3 Core Pool, the one `UmbrellaEthereum.UMBRELLA.POOL()` returns.
    expect(filter.addresses.map((a) => bytesToHex(a))).toEqual([
      '0x87870bca3f3fd6335c3f4ce8392d69350b4fa4e2',
    ]);
    expect(filter.topics[0].values.map((t) => bytesToHex(t))).toEqual([DEFICIT_CREATED]);
    expect(filter.confidence).toBe(EVM_PB.ConfidenceLevel.LATEST);
  });

  test('the log trigger runs the DeficitCreated handler with empty checkData', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    let checkData: Hex | undefined;
    evmMock.callContract = checkUpkeepMock(false, '0x', (data) => (checkData = data));
    const [, logEntry] = initWorkflow({schedule: '0 * * * *', evms: [NETWORK]}) as unknown as {
      fn: (runtime: never, payload: unknown) => string;
    }[];
    const logTxHash = ('0x' + '22'.repeat(32)) as Hex;

    const runtime = newTestRuntime();
    logEntry.fn(runtime as never, {txHash: hexToBytes(logTxHash), blockNumber: 1n});
    expect(checkData).toBe('0x');
    expect(runtime.getLogs().find((l) => l.includes(`DeficitCreated ${logTxHash}`))).toBeDefined();
  });

  test('skips networks with empty receiver', () => {
    const handlers = initWorkflow({
      schedule: '* * * * *',
      evms: [{chainName: CHAIN_NAME, isTestnet: false, receiver: ''}],
    });
    expect(handlers.length).toBe(0);
  });

  test('creates only the cron handler for a chain without a known Pool', () => {
    const handlers = initWorkflow({
      schedule: '* * * * *',
      evms: [{chainName: 'avalanche-mainnet', isTestnet: false, receiver: RECEIVER}],
    });
    expect(handlers.length).toBe(1);
  });
});
