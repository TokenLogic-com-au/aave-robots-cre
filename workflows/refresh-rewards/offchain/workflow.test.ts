import {describe, expect} from 'bun:test';
import {TxStatus, getNetwork} from '@chainlink/cre-sdk';
import {EvmMock, newTestRuntime, test} from '@chainlink/cre-sdk/test';
import {bytesToHex, decodeFunctionData, hexToBytes, type Hex} from 'viem';

import {
  CHECK_UPKEEP_SELECTOR,
  encodeCheckUpkeepResult,
  type CallContractInput,
} from '../../shared/offchain/testing/mocks';
import {IAaveCREReceiverABI} from '../../shared/offchain/abi/IAaveCREReceiver';
import {configSchema, createFactoryHandler, encodeCheckData, initWorkflow} from './workflow';
import productionConfig from './config.production.json';

const CHAIN_NAME = 'ethereum-mainnet';
const CHAIN_SELECTOR = getNetwork({
  chainFamily: 'evm',
  chainSelectorName: CHAIN_NAME,
  isTestnet: false,
})!.chainSelector.selector;

const RECEIVER = '0x1111111111111111111111111111111111111111' as Hex;
const FACTORY = '0x2222222222222222222222222222222222222222' as Hex;
const TX_HASH = ('0xab' + 'cd'.repeat(31)) as Hex;
// The workflow treats performData as opaque (it only signs it), so any non-empty payload works.
const PERFORM_DATA = '0xdeadbeef' as Hex;

const NETWORK = {chainName: CHAIN_NAME, isTestnet: false, receiver: RECEIVER, factories: [FACTORY]};

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

const handle = createFactoryHandler(NETWORK, FACTORY);

describe('refresh-rewards workflow', () => {
  test('returns "No refresh needed" when checkUpkeep is false', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(false, '0x');

    expect(handle(newTestRuntime() as never)).toBe('No refresh needed');
  });

  test('sends only the factory as checkData', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    let checkData: Hex | undefined;
    evmMock.callContract = (req: CallContractInput) => {
      const {args} = decodeFunctionData({
        abi: IAaveCREReceiverABI,
        data: bytesToHex(req.call.data),
      });
      checkData = args?.[0] as Hex;
      return {data: encodeCheckUpkeepResult(false, '0x')};
    };

    handle(newTestRuntime() as never);
    expect(checkData).toBe(encodeCheckData(FACTORY));
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
    let written = false;
    evmMock.writeReport = () => {
      written = true;
      return {txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)};
    };

    expect(handle(newTestRuntime() as never)).toBe('submit skipped');
    expect(written).toBe(false);
  });

  test('submits the report and returns the tx hash on success', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true);
    evmMock.estimateGas = () => ({gas: 100_000n});
    let receiver: Hex | undefined;
    evmMock.writeReport = (input) => {
      receiver = bytesToHex(input.receiver);
      return {txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)};
    };

    expect(handle(newTestRuntime() as never)).toBe(`refreshed, tx=${TX_HASH}`);
    expect(receiver).toBe(RECEIVER);
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
    const badHandle = createFactoryHandler(badNetwork, FACTORY);
    expect(badHandle(newTestRuntime() as never)).toBe('Network not found');
  });
});

describe('initWorkflow', () => {
  test('creates one handler per factory', () => {
    const handlers = initWorkflow({
      schedule: '* * * * *',
      evms: [
        {
          chainName: CHAIN_NAME,
          isTestnet: false,
          receiver: RECEIVER,
          factories: [FACTORY, FACTORY],
        },
      ],
    });
    expect(handlers.length).toBe(2);
  });

  // CRE caps triggers per workflow at 10 (PerWorkflow.TriggerSubscriptionLimit).
  test('production config stays within the CRE trigger limit', () => {
    const config = configSchema.parse(productionConfig);
    const evms = config.evms.map((net) => ({...net, receiver: RECEIVER}));
    expect(initWorkflow({...config, evms}).length).toBeLessThanOrEqual(10);
  });

  test('skips networks with empty receiver', () => {
    const handlers = initWorkflow({
      schedule: '* * * * *',
      evms: [{chainName: CHAIN_NAME, isTestnet: false, receiver: '', factories: [FACTORY]}],
    });
    expect(handlers.length).toBe(0);
  });

  test('sums handlers across networks', () => {
    const handlers = initWorkflow({
      schedule: '* * * * *',
      evms: [
        {
          chainName: CHAIN_NAME,
          isTestnet: false,
          receiver: RECEIVER,
          factories: [FACTORY, FACTORY],
        },
        {
          chainName: 'avalanche-mainnet',
          isTestnet: false,
          receiver: RECEIVER,
          factories: [FACTORY],
        },
      ],
    });
    expect(handlers.length).toBe(3);
  });
});
