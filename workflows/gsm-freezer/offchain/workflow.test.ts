import {describe, expect} from 'bun:test';
import {TxStatus} from '@chainlink/cre-sdk';
import {EvmMock, newTestRuntime, test} from '@chainlink/cre-sdk/test';
import {bytesToHex, hexToBytes, type Hex} from 'viem';

import {
  chainSelectorOf,
  checkUpkeepMock,
  encodeCheckUpkeepResult,
  type CallContractInput,
} from '../../shared/offchain/testing/mocks';
import {createReceiverHandler, initWorkflow} from './workflow';

const CHAIN_NAME = 'ethereum-mainnet';
const CHAIN_SELECTOR = chainSelectorOf(CHAIN_NAME);

const RECEIVER = '0x1111111111111111111111111111111111111111' as Hex;
const TX_HASH = ('0xab' + 'cd'.repeat(31)) as Hex;
// The workflow passes performData through unchanged, so any non-empty payload works.
const PERFORM_DATA = '0xdeadbeef' as Hex;

const NETWORK = {chainName: CHAIN_NAME, isTestnet: false, receiver: RECEIVER};

const handle = createReceiverHandler(NETWORK);

describe('gsm-freezer workflow', () => {
  test('returns "No action needed" when checkUpkeep is false', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(false);

    expect(handle(newTestRuntime() as never)).toBe('No action needed');
  });

  test('returns "No action needed" when checkUpkeep returns empty data', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = () => ({data: new Uint8Array(0)});

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('No action needed');
    expect(runtime.getLogs().find((l) => l.includes('returned empty data'))).toBeDefined();
  });

  test('returns "No action needed" and logs when checkUpkeep reverts', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = () => {
      throw new Error('checkUpkeep reverted');
    };

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('No action needed');
    expect(
      runtime.getLogs().find((l) => l.includes('checkUpkeep reverted — skipping')),
    ).toBeDefined();
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

    expect(handle(newTestRuntime() as never)).toBe(`action submitted, tx=${TX_HASH}`);
  });

  test('returns "submit skipped" and logs when writeReport is not SUCCESS', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true, PERFORM_DATA);
    evmMock.estimateGas = () => ({gas: 100_000n});
    evmMock.writeReport = () => ({
      txStatus: TxStatus.REVERTED,
      txHash: new Uint8Array(0),
      errorMessage: 'reverted',
    });

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('submit skipped');
    expect(runtime.getLogs().find((l) => l.includes('writeReport status='))).toBeDefined();
  });

  test('returns "Network not found" for an unknown chain', () => {
    const badHandle = createReceiverHandler({...NETWORK, chainName: 'made-up-chain'});
    expect(badHandle(newTestRuntime() as never)).toBe('Network not found');
  });
});

describe('checkUpkeep call', () => {
  test('calls checkUpkeep on the configured receiver with empty checkData', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    let to: Hex | undefined;
    let checkData: Hex | undefined;
    const mock = checkUpkeepMock(false, '0x', (data) => (checkData = data));
    evmMock.callContract = (req: CallContractInput) => {
      to = bytesToHex(req.call.to);
      return mock(req);
    };

    handle(newTestRuntime() as never);
    expect(to).toBe(RECEIVER);
    expect(checkData).toBe('0x');
  });

  test('returns "Processing failed" and logs when the write throws', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true, PERFORM_DATA);
    evmMock.estimateGas = () => ({gas: 100_000n});
    evmMock.writeReport = () => {
      throw new Error('boom');
    };

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('Processing failed');
    expect(
      runtime.getLogs().find((l) => l.includes('failed:') && l.includes('boom')),
    ).toBeDefined();
  });
});

describe('initWorkflow', () => {
  test('creates one handler per network with a receiver', () => {
    const handlers = initWorkflow({schedule: '* * * * *', evms: [NETWORK]});
    expect(handlers.length).toBe(1);
  });

  test('skips networks with empty receiver', () => {
    const handlers = initWorkflow({
      schedule: '* * * * *',
      evms: [{chainName: CHAIN_NAME, isTestnet: false, receiver: ''}],
    });
    expect(handlers.length).toBe(0);
  });

  test('creates one handler per GSM receiver, each calling its own receiver', () => {
    const otherReceiver = '0x2222222222222222222222222222222222222222' as Hex;
    const handlers = initWorkflow({
      schedule: '*/30 * * * * *',
      evms: [NETWORK, {...NETWORK, receiver: otherReceiver}],
    }) as unknown as {
      trigger: {config: {schedule: string}};
      fn: (runtime: never, payload: unknown) => string;
    }[];
    expect(handlers.length).toBe(2);
    expect(handlers.map((h) => h.trigger.config.schedule)).toEqual([
      '*/30 * * * * *',
      '*/30 * * * * *',
    ]);

    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    const called: Hex[] = [];
    evmMock.callContract = (req: CallContractInput) => {
      called.push(bytesToHex(req.call.to));
      return {data: encodeCheckUpkeepResult(false, '0x')};
    };
    handlers.forEach((h) => h.fn(newTestRuntime() as never, {}));
    expect(called).toEqual([RECEIVER, otherReceiver]);
  });
});
