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
import productionConfig from './config.production.json';

const VOTING_CHAINS = ['ethereum-mainnet', 'avalanche-mainnet', 'polygon-mainnet'];

function chainSelector(chainName: string): bigint {
  return getNetwork({chainFamily: 'evm', chainSelectorName: chainName, isTestnet: false})!
    .chainSelector.selector;
}

const CHAIN_NAME = 'ethereum-mainnet';
const CHAIN_SELECTOR = chainSelector(CHAIN_NAME);

const RECEIVER = '0x1111111111111111111111111111111111111111' as Hex;
const TX_HASH = ('0xab' + 'cd'.repeat(31)) as Hex;
// The workflow passes performData through unchanged, so any non-empty payload works.
const PERFORM_DATA = '0xdeadbeef' as Hex;

const NETWORK = {chainName: CHAIN_NAME, isTestnet: false, receiver: RECEIVER};

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

// Largest onReport estimate that still fits a write (fitsWriteQuota rounds down).
const MAX_ESTIMATE = ((MAX_WRITE_GAS - WRITE_OVERHEAD_GAS + 1n) * 63n - 1n) / 64n;

const handle = createReceiverHandler(NETWORK);

describe('voting-chain-robot workflow', () => {
  test('returns "No action needed" when checkUpkeep is false', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(false, '0x');

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

  test('returns "submit skipped" without writing when estimateGas reverts', () => {
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

  test('skips and logs a report estimated above the CRE write quota', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true);
    let estimates = 0;
    evmMock.estimateGas = () => {
      estimates++;
      return {gas: MAX_ESTIMATE + 1n};
    };
    let written = false;
    evmMock.writeReport = () => {
      written = true;
      return {txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)};
    };

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('submit skipped');
    expect(written).toBe(false);
    expect(estimates).toBe(1);
    expect(runtime.getLogs().find((l) => l.includes('exceeds the CRE write quota'))).toBeDefined();
  });

  test('writes a report at the largest estimate that fits, estimating once, without gasConfig', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true);
    let estimates = 0;
    evmMock.estimateGas = () => {
      estimates++;
      return {gas: MAX_ESTIMATE};
    };
    let gasConfigSent = true;
    evmMock.writeReport = (input) => {
      gasConfigSent = input.gasConfig !== undefined;
      return {txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)};
    };

    expect(handle(newTestRuntime() as never)).toBe(`actions performed, tx=${TX_HASH}`);
    expect(estimates).toBe(1);
    expect(gasConfigSent).toBe(false);
  });

  test('returns "onReport reverted" and logs when onReport reverts inside the write', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true);
    evmMock.estimateGas = () => ({gas: 100_000n});
    evmMock.writeReport = () => ({
      txStatus: TxStatus.SUCCESS,
      receiverContractExecutionStatus: EVM_PB.ReceiverContractExecutionStatus.REVERTED,
      txHash: hexToBytes(TX_HASH),
    });

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe(`onReport reverted, tx=${TX_HASH}`);
    expect(runtime.getLogs().find((l) => l.includes('onReport reverted in tx'))).toBeDefined();
  });

  test('estimates and writes onReport with the checkUpkeep performData to the receiver', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true);
    const estimated: Hex[] = [];
    evmMock.estimateGas = (input) => {
      const {functionName, args} = decodeFunctionData({
        abi: IAaveCREReceiverABI,
        data: bytesToHex(input.msg!.data),
      });
      expect(functionName).toBe('onReport');
      estimated.push(args?.[1] as Hex);
      return {gas: 100_000n};
    };
    let receiver: Hex | undefined;
    evmMock.writeReport = (input) => {
      receiver = bytesToHex(input.receiver);
      return {txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)};
    };

    expect(handle(newTestRuntime() as never)).toBe(`actions performed, tx=${TX_HASH}`);
    expect(estimated).toEqual([PERFORM_DATA]);
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

  test('returns "Processing failed" and logs when the write throws', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true);
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

  test('calls checkUpkeep on the configured receiver with empty checkData', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    let to: Hex | undefined;
    let checkData: Hex | undefined;
    evmMock.callContract = (req: CallContractInput) => {
      to = bytesToHex(req.call.to);
      const {args} = decodeFunctionData({
        abi: IAaveCREReceiverABI,
        data: bytesToHex(req.call.data),
      });
      checkData = args?.[0] as Hex;
      return {data: encodeCheckUpkeepResult(false, '0x')};
    };

    handle(newTestRuntime() as never);
    expect(to).toBe(RECEIVER);
    expect(checkData).toBe('0x');
  });

  test('returns "Network not found" for an unknown chain', () => {
    const badHandle = createReceiverHandler({...NETWORK, chainName: 'made-up-chain'});
    expect(badHandle(newTestRuntime() as never)).toBe('Network not found');
  });
});

describe('initWorkflow', () => {
  test('MAX_WRITE_GAS is the current CRE write gas quota', () => {
    expect(MAX_WRITE_GAS).toBe(16_777_216n);
  });

  test('fitsWriteQuota leaves room for the 63/64 rule and the forwarder overhead', () => {
    expect(fitsWriteQuota(MAX_ESTIMATE)).toBe(true);
    expect(fitsWriteQuota(MAX_ESTIMATE + 1n)).toBe(false);
    expect(fitsWriteQuota(MAX_WRITE_GAS - WRITE_OVERHEAD_GAS)).toBe(false);
  });

  test('production config covers the three voting chains', () => {
    const config = configSchema.parse(productionConfig);
    expect(config.evms.map((net) => net.chainName)).toEqual(VOTING_CHAINS);
    config.evms.forEach((net) => expect(chainSelector(net.chainName)).toBeDefined());
  });

  test('skips networks with empty receiver', () => {
    const handlers = initWorkflow({
      schedule: '* * * * *',
      evms: [{chainName: CHAIN_NAME, isTestnet: false, receiver: ''}],
    });
    expect(handlers.length).toBe(0);
  });

  test('creates one handler per voting chain, each calling its own receiver on its chain', () => {
    const receivers = VOTING_CHAINS.map((_, i) => `0x${String(i + 1).repeat(40)}` as Hex);
    const handlers = initWorkflow({
      schedule: productionConfig.schedule,
      evms: VOTING_CHAINS.map((chainName, i) => ({
        chainName,
        isTestnet: false,
        receiver: receivers[i],
      })),
    }) as unknown as {
      trigger: {config: {schedule: string}};
      fn: (runtime: never, payload: unknown) => string;
    }[];
    expect(handlers.length).toBe(VOTING_CHAINS.length);
    expect(handlers.every((h) => h.trigger.config.schedule === productionConfig.schedule)).toBe(
      true,
    );

    const called: string[] = [];
    VOTING_CHAINS.forEach((chainName) => {
      EvmMock.testInstance(chainSelector(chainName)).callContract = (req: CallContractInput) => {
        called.push(`${chainName}:${bytesToHex(req.call.to)}`);
        return {data: encodeCheckUpkeepResult(false, '0x')};
      };
    });
    handlers.forEach((h) => h.fn(newTestRuntime() as never, {}));
    expect(called).toEqual(VOTING_CHAINS.map((chainName, i) => `${chainName}:${receivers[i]}`));
  });
});
