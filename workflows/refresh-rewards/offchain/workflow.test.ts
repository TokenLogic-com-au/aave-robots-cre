import {describe, expect} from 'bun:test';
import {TxStatus, getNetwork} from '@chainlink/cre-sdk';
import {EvmMock, newTestRuntime, test} from '@chainlink/cre-sdk/test';
import {bytesToHex, hexToBytes, type Hex} from 'viem';

import {
  CHECK_UPKEEP_SELECTOR,
  encodeCheckUpkeepResult,
  type CallContractInput,
} from '../../shared/offchain/testing/mocks';
import {createPoolHandler, initWorkflow} from './workflow';

const CHAIN_NAME = 'ethereum-mainnet';
const CHAIN_SELECTOR = getNetwork({
  chainFamily: 'evm',
  chainSelectorName: CHAIN_NAME,
  isTestnet: false,
})!.chainSelector.selector;

const RECEIVER = '0x1111111111111111111111111111111111111111' as Hex;
const FACTORY = '0x2222222222222222222222222222222222222222' as Hex;
const CONTROLLER = '0x3333333333333333333333333333333333333333' as Hex;
const TX_HASH = ('0xab' + 'cd'.repeat(31)) as Hex;
// The workflow treats performData as opaque (it only signs it), so any non-empty payload works.
const PERFORM_DATA = '0xdeadbeef' as Hex;

const POOL = {factory: FACTORY, controller: CONTROLLER};
const NETWORK = {chainName: CHAIN_NAME, isTestnet: false, receiver: RECEIVER, pools: [POOL]};

// Mock `callContract` for a single `checkUpkeep` call, returning the given result.
function checkUpkeepMock(upkeepNeeded: boolean, performData: Hex = PERFORM_DATA) {
  return (req: CallContractInput): {data: Uint8Array} => {
    const selector = bytesToHex(req.call.data).slice(0, 10).toLowerCase();
    if (selector === CHECK_UPKEEP_SELECTOR) {
      return {data: encodeCheckUpkeepResult(upkeepNeeded, performData)};
    }
    throw new Error(`checkUpkeepMock: unmocked selector ${selector}`);
  };
}

const handle = createPoolHandler(NETWORK, POOL);

describe('refresh-rewards workflow', () => {
  test('returns "No refresh needed" when checkUpkeep is false', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(false, '0x');

    expect(handle(newTestRuntime() as never)).toBe('No refresh needed');
  });

  test('returns "No refresh needed" when checkUpkeep returns empty data', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = () => ({data: new Uint8Array(0)});

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('No refresh needed');
    expect(runtime.getLogs().find((l) => l.includes('returned empty data'))).toBeDefined();
  });

  test('returns "No refresh needed" and logs when checkUpkeep reverts', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = () => {
      throw new Error('checkUpkeep reverted');
    };

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('No refresh needed');
    expect(
      runtime.getLogs().find((l) => l.includes('checkUpkeep reverted — skipping')),
    ).toBeDefined();
  });

  test('returns "submit skipped" when estimateGas reverts', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true);
    evmMock.estimateGas = () => {
      throw new Error('reverted');
    };

    expect(handle(newTestRuntime() as never)).toBe('submit skipped');
  });

  test('submits the report and returns the tx hash on success', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true);
    evmMock.estimateGas = () => ({gas: 100_000n});
    evmMock.writeReport = () => ({txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)});

    expect(handle(newTestRuntime() as never)).toBe(`refreshed, tx=${TX_HASH}`);
  });

  test('returns "submit skipped" and logs when writeReport is not SUCCESS', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true);
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
    const badNetwork = {...NETWORK, chainName: 'made-up-chain'};
    const badHandle = createPoolHandler(badNetwork, POOL);
    expect(badHandle(newTestRuntime() as never)).toBe('Network not found');
  });
});

describe('initWorkflow', () => {
  test('creates one handler per pool', () => {
    const handlers = initWorkflow({
      schedule: '* * * * *',
      evms: [{chainName: CHAIN_NAME, isTestnet: false, receiver: RECEIVER, pools: [POOL, POOL]}],
    });
    expect(handlers.length).toBe(2);
  });

  test('skips networks with empty receiver', () => {
    const handlers = initWorkflow({
      schedule: '* * * * *',
      evms: [{chainName: CHAIN_NAME, isTestnet: false, receiver: '', pools: [POOL]}],
    });
    expect(handlers.length).toBe(0);
  });

  test('sums handlers across networks', () => {
    const handlers = initWorkflow({
      schedule: '* * * * *',
      evms: [
        {chainName: CHAIN_NAME, isTestnet: false, receiver: RECEIVER, pools: [POOL, POOL]},
        {chainName: 'avalanche-mainnet', isTestnet: false, receiver: RECEIVER, pools: [POOL]},
      ],
    });
    expect(handlers.length).toBe(3);
  });
});
