import {describe, expect} from 'bun:test';
import {TxStatus, getNetwork} from '@chainlink/cre-sdk';
import {EVM_PB} from '@chainlink/cre-sdk/pb';
import {EvmMock, newTestRuntime, test} from '@chainlink/cre-sdk/test';
import {bytesToHex, decodeFunctionData, hexToBytes, type Hex} from 'viem';

import {
  CHECK_UPKEEP_SELECTOR,
  encodeCheckUpkeepResult,
  type CallContractInput,
} from '../../shared/offchain/testing/mocks';
import {IAaveCREReceiverABI} from '../../shared/offchain/abi/IAaveCREReceiver';
import {
  MAX_WRITE_GAS,
  WRITE_OVERHEAD_GAS,
  configSchema,
  createReceiverHandler,
  fitsWriteQuota,
  initWorkflow,
} from './workflow';

// Largest estimate with estimate * 64 / 63 + WRITE_OVERHEAD_GAS <= MAX_WRITE_GAS.
const MAX_ESTIMATE = 16_268_979n;

const CHAIN_NAME = 'ethereum-mainnet';
const CHAIN_SELECTOR = getNetwork({
  chainFamily: 'evm',
  chainSelectorName: CHAIN_NAME,
  isTestnet: false,
})!.chainSelector.selector;

const RECEIVER = '0x1111111111111111111111111111111111111111' as Hex;
const TX_HASH = ('0xab' + 'cd'.repeat(31)) as Hex;
// The workflow treats performData as opaque (it only signs it), so any non-empty payload works.
const PERFORM_DATA = '0xdeadbeef' as Hex;

const NETWORK = {chainName: CHAIN_NAME, isTestnet: false, receiver: RECEIVER};

type EstimateGasInput = {msg: {to: Uint8Array; data: Uint8Array}};

// Mocks callContract for a single checkUpkeep call, returning the given result.
function checkUpkeepMock(upkeepNeeded: boolean, performData: Hex = PERFORM_DATA) {
  return (req: CallContractInput): {data: Uint8Array} => {
    const selector = bytesToHex(req.call.data).slice(0, 10).toLowerCase();
    if (selector === CHECK_UPKEEP_SELECTOR) {
      return {data: encodeCheckUpkeepResult(upkeepNeeded, performData)};
    }
    throw new Error(`checkUpkeepMock: unmocked selector ${selector}`);
  };
}

const handle = createReceiverHandler(NETWORK);

describe('governance chain robot workflow', () => {
  test('returns "No action needed" when checkUpkeep is false', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(false, '0x');

    expect(handle(newTestRuntime() as never)).toBe('No action needed');
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

  test('calls checkUpkeep with empty checkData', () => {
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
    expect(checkData).toBe('0x');
  });

  test('returns "submit skipped" and logs when estimateGas reverts', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true);
    evmMock.estimateGas = () => {
      throw new Error('NoActionCanBePerformed');
    };

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('submit skipped');
    expect(runtime.getLogs().find((l) => l.includes('estimateGas failed'))).toBeDefined();
  });

  test('estimates onReport on the receiver with the checkUpkeep performData', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true);
    let estimated: {to: Hex; args: readonly unknown[] | undefined} | undefined;
    evmMock.estimateGas = (req: EstimateGasInput) => {
      const {functionName, args} = decodeFunctionData({
        abi: IAaveCREReceiverABI,
        data: bytesToHex(req.msg.data),
      });
      expect(functionName).toBe('onReport');
      estimated = {to: bytesToHex(req.msg.to), args};
      return {gas: 100_000n};
    };
    evmMock.writeReport = () => ({txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)});

    handle(newTestRuntime() as never);
    expect(estimated?.to).toBe(RECEIVER);
    expect(estimated?.args).toEqual(['0x', PERFORM_DATA]);
  });

  test('returns "submit skipped" and logs when the estimate exceeds the write quota', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true);
    evmMock.estimateGas = () => ({gas: MAX_ESTIMATE + 1n});
    let written = false;
    evmMock.writeReport = () => {
      written = true;
      return {txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)};
    };

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('submit skipped');
    expect(written).toBe(false);
    expect(runtime.getLogs().find((l) => l.includes('exceeds max write gas'))).toBeDefined();
  });

  test('submits at the largest estimate that fits the write quota', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true);
    evmMock.estimateGas = () => ({gas: MAX_ESTIMATE});
    evmMock.writeReport = () => ({txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)});

    expect(handle(newTestRuntime() as never)).toBe(`actions performed, tx=${TX_HASH}`);
  });

  test('writes the signed performData to the receiver without a gas config', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true);
    evmMock.estimateGas = () => ({gas: 100_000n});
    let written: {receiver: Hex; gasConfig: unknown} | undefined;
    evmMock.writeReport = (input) => {
      written = {receiver: bytesToHex(input.receiver), gasConfig: input.gasConfig};
      return {txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)};
    };

    expect(handle(newTestRuntime() as never)).toBe(`actions performed, tx=${TX_HASH}`);
    expect(written).toEqual({receiver: RECEIVER, gasConfig: undefined});
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

  test('returns "submit skipped" and logs when onReport reverted in the forwarder tx', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true);
    evmMock.estimateGas = () => ({gas: 100_000n});
    evmMock.writeReport = () => ({
      txStatus: TxStatus.SUCCESS,
      txHash: hexToBytes(TX_HASH),
      receiverContractExecutionStatus: EVM_PB.ReceiverContractExecutionStatus.REVERTED,
    });

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('submit skipped');
    expect(
      runtime.getLogs().find((l) => l.includes(`onReport reverted in the forwarder tx ${TX_HASH}`)),
    ).toBeDefined();
  });

  test('returns "submit skipped" and logs when writeReport has no tx hash', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true);
    evmMock.estimateGas = () => ({gas: 100_000n});
    evmMock.writeReport = () => ({txStatus: TxStatus.SUCCESS, txHash: new Uint8Array(0)});

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('submit skipped');
    expect(runtime.getLogs().find((l) => l.includes('no txHash'))).toBeDefined();
  });

  test('returns "Network not found" for an unknown chain', () => {
    const badHandle = createReceiverHandler({...NETWORK, chainName: 'made-up-chain'});
    expect(badHandle(newTestRuntime() as never)).toBe('Network not found');
  });
});

describe('configSchema', () => {
  const config = (receiver: string) => ({
    schedule: '* * * * *',
    evms: [{chainName: CHAIN_NAME, receiver}],
  });

  test('normalizes the receiver address casing', () => {
    const parsed = configSchema.parse(config('0x9aee0b04504cef83a65ac3f0e838d0593bcb2bc7'));
    expect(parsed.evms[0].receiver).toBe('0x9AEE0B04504CeF83A65AC3f0e838D0593BCb2BC7');
  });

  test('accepts an empty receiver', () => {
    expect(configSchema.parse(config('')).evms[0].receiver).toBe('');
  });

  test('rejects an invalid receiver', () => {
    expect(() => configSchema.parse(config('0x1234'))).toThrow();
  });
});

describe('fitsWriteQuota', () => {
  test('adds the forwarder overhead and the withheld 1/64 to the estimate', () => {
    expect(fitsWriteQuota(MAX_ESTIMATE)).toBe(true);
    expect(fitsWriteQuota(MAX_ESTIMATE + 1n)).toBe(false);
    expect(fitsWriteQuota(MAX_WRITE_GAS - WRITE_OVERHEAD_GAS)).toBe(false);
  });
});

describe('initWorkflow', () => {
  test('creates one cron handler per network with a receiver', () => {
    const handlers = initWorkflow({
      schedule: '*/30 * * * * *',
      evms: [NETWORK, {chainName: CHAIN_NAME, isTestnet: false, receiver: ''}],
    }) as unknown as {trigger: {config: Record<string, unknown>}}[];
    expect(handlers.length).toBe(1);
    expect(handlers[0].trigger.config.schedule).toBe('*/30 * * * * *');
  });
});
