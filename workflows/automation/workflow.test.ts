import {describe, expect} from 'bun:test';
import {TxStatus, getNetwork} from '@chainlink/cre-sdk';
import {EvmMock, newTestRuntime, test} from '@chainlink/cre-sdk/test';
import {encodeAbiParameters, hexToBytes, parseAbiParameters, type Hex} from 'viem';

import {createAutomationHandler, createHandlers} from './handlers';

const CHAIN_NAME = 'ethereum-mainnet';
const CHAIN_SELECTOR = getNetwork({
  chainFamily: 'evm',
  chainSelectorName: CHAIN_NAME,
  isTestnet: false,
})!.chainSelector.selector;

const ROBOT = '0x1111111111111111111111111111111111111111' as Hex;
const MAILBOX = '0x2222222222222222222222222222222222222222' as Hex;
const TX_HASH = ('0xab' + 'cd'.repeat(31)) as Hex;
const PERFORM_DATA = '0xdeadbeef' as Hex;

// Encode a `checkUpkeep(bytes) -> (bool, bytes)` return value the way the robot would.
function checkUpkeepResult(needed: boolean, performData: Hex): Uint8Array {
  return hexToBytes(encodeAbiParameters(parseAbiParameters('bool, bytes'), [needed, performData]));
}

const handle = createAutomationHandler(CHAIN_NAME, MAILBOX, ROBOT, '0x');

describe('automation handler', () => {
  test('returns "No upkeep needed" when checkUpkeep is false', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = () => ({data: checkUpkeepResult(false, '0x')});

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('No upkeep needed');
  });

  test('returns "No upkeep needed" when checkUpkeep returns empty data', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = () => ({data: new Uint8Array(0)});

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('No upkeep needed');
  });

  test('returns "Processing failed" when checkUpkeep reverts', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = () => {
      throw new Error('checkUpkeep reverted');
    };

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('Processing failed');
  });

  test('skips the write when estimateGas reverts', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = () => ({data: checkUpkeepResult(true, PERFORM_DATA)});
    evmMock.estimateGas = () => {
      throw new Error('reverted');
    };

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('No upkeep needed');
    expect(runtime.getLogs().find((l) => l.includes('estimate gas failed'))).toBeDefined();
  });

  test('submits the report and returns the tx hash on success', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = () => ({data: checkUpkeepResult(true, PERFORM_DATA)});
    evmMock.estimateGas = () => ({gas: 100_000n});
    evmMock.writeReport = () => ({txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)});

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe(TX_HASH);
  });

  test('skips and logs when writeReport status is not SUCCESS', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = () => ({data: checkUpkeepResult(true, PERFORM_DATA)});
    evmMock.estimateGas = () => ({gas: 100_000n});
    evmMock.writeReport = () => ({
      txStatus: TxStatus.REVERTED,
      txHash: new Uint8Array(0),
      errorMessage: 'reverted',
    });

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('No upkeep needed');
    expect(runtime.getLogs().find((l) => l.includes('writeReport status='))).toBeDefined();
  });
});

describe('createHandlers', () => {
  const network = (automations: {address: string; checkData: string}[]) => ({
    schedule: '*/5 * * * *',
    evms: [{chainName: CHAIN_NAME, mailboxAddress: MAILBOX, automations}],
  });

  test('creates one handler per automation', () => {
    const handlers = createHandlers(
      network([
        {address: ROBOT, checkData: '0x'},
        {address: ROBOT, checkData: '0x'},
      ]),
    );
    expect(handlers.length).toBe(2);
  });

  test('skips networks with no automations', () => {
    expect(createHandlers(network([])).length).toBe(0);
  });

  test('skips automations with empty address', () => {
    const handlers = createHandlers(network([{address: '', checkData: '0x'}]));
    expect(handlers.length).toBe(0);
  });
});
