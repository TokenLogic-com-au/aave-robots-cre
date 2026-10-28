import {describe, expect} from 'bun:test';
import {TxStatus} from '@chainlink/cre-sdk';
import {EVM_PB} from '@chainlink/cre-sdk/pb';
import {EvmMock, newTestRuntime, test} from '@chainlink/cre-sdk/test';
import {bytesToHex, decodeFunctionData, hexToBytes, zeroAddress, type Hex} from 'viem';

import {IAaveCREReceiverABI} from '../abi/IAaveCREReceiver';
import {
  estimateOnReport,
  fitsWriteQuota,
  requiredWriteGas,
  shouldSubmit,
  submitReport,
} from '../checkUpkeep';
import {MAX_WRITE_GAS, WRITE_OVERHEAD_GAS} from '../constants';
import {getEvmClient} from '../network';
import {chainSelectorOf, checkUpkeepMock, type CallContractInput} from '../testing/mocks';

// Largest estimates with estimate * 64 / 63 + WRITE_OVERHEAD_GAS within the default quota
// (MAX_WRITE_GAS) and within Ethereum's.
const MAX_ESTIMATE = 9_597_657n;
const ETHEREUM_MAX_ESTIMATE = 16_268_979n;

const CHAIN_NAME = 'ethereum-mainnet';
const CHAIN_SELECTOR = chainSelectorOf(CHAIN_NAME);
const RECEIVER = '0x1111111111111111111111111111111111111111' as Hex;
const FORWARDER = '0x2222222222222222222222222222222222222222' as Hex;
const WORKFLOW_ID = ('0x' + '33'.repeat(32)) as Hex;
const TX_HASH = ('0xab' + 'cd'.repeat(31)) as Hex;
const PERFORM_DATA = '0xdeadbeef' as Hex;
const LABEL = 'test';

type EstimateGasInput = {msg: {from: Uint8Array; to: Uint8Array; data: Uint8Array}};
type WriteReportInput = {receiver: Uint8Array; gasConfig?: {gasLimit: bigint | string}};

function evmClient() {
  return getEvmClient({chainName: CHAIN_NAME})!;
}

function success() {
  return {txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)};
}

describe('shouldSubmit', () => {
  test('returns performData when upkeep is needed', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    let checkData: Hex | undefined;
    evmMock.callContract = checkUpkeepMock(true, PERFORM_DATA, (d) => (checkData = d));

    const runtime = newTestRuntime();
    expect(shouldSubmit(runtime, evmClient(), RECEIVER, '0x1234', LABEL)).toBe(PERFORM_DATA);
    expect(checkData).toBe('0x1234');
  });

  test('returns null when upkeep is not needed', () => {
    EvmMock.testInstance(CHAIN_SELECTOR).callContract = checkUpkeepMock(false);
    expect(shouldSubmit(newTestRuntime(), evmClient(), RECEIVER, '0x', LABEL)).toBeNull();
  });

  test('returns null and logs when checkUpkeep reverts', () => {
    EvmMock.testInstance(CHAIN_SELECTOR).callContract = () => {
      throw new Error('boom');
    };
    const runtime = newTestRuntime();
    expect(shouldSubmit(runtime, evmClient(), RECEIVER, '0x', LABEL)).toBeNull();
    expect(runtime.getLogs().some((l) => l.includes('checkUpkeep reverted — skipping'))).toBe(true);
  });

  test('returns null and logs when checkUpkeep returns no data', () => {
    EvmMock.testInstance(CHAIN_SELECTOR).callContract = () => ({data: new Uint8Array()});
    const runtime = newTestRuntime();
    expect(shouldSubmit(runtime, evmClient(), RECEIVER, '0x', LABEL)).toBeNull();
    expect(runtime.getLogs().some((l) => l.includes('empty data'))).toBe(true);
  });

  test('reads at the given block number', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    let blockNumber: unknown;
    evmMock.callContract = (req: CallContractInput & {blockNumber?: unknown}) => {
      blockNumber = req.blockNumber;
      return checkUpkeepMock(true, PERFORM_DATA)(req);
    };

    shouldSubmit(newTestRuntime(), evmClient(), RECEIVER, '0x', LABEL, 1234n);
    expect(blockNumber).toBeDefined();
  });
});

describe('estimateOnReport', () => {
  test('estimates onReport as the zero address with empty metadata by default', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    let call: {from: Hex; to: Hex; args: readonly unknown[] | undefined} | undefined;
    evmMock.estimateGas = (req: EstimateGasInput) => {
      const {functionName, args} = decodeFunctionData({
        abi: IAaveCREReceiverABI,
        data: bytesToHex(req.msg.data),
      });
      expect(functionName).toBe('onReport');
      call = {from: bytesToHex(req.msg.from), to: bytesToHex(req.msg.to), args};
      return {gas: 100_000n};
    };

    expect(estimateOnReport(newTestRuntime(), evmClient(), RECEIVER, PERFORM_DATA, LABEL)).toBe(
      100_000n,
    );
    expect(call).toEqual({from: zeroAddress, to: RECEIVER, args: ['0x', PERFORM_DATA]});
  });

  test('estimates as `from` with `metadata`', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    let call: {from: Hex; args: readonly unknown[] | undefined} | undefined;
    evmMock.estimateGas = (req: EstimateGasInput) => {
      const {args} = decodeFunctionData({abi: IAaveCREReceiverABI, data: bytesToHex(req.msg.data)});
      call = {from: bytesToHex(req.msg.from), args};
      return {gas: 1n};
    };

    estimateOnReport(newTestRuntime(), evmClient(), RECEIVER, PERFORM_DATA, LABEL, {
      from: FORWARDER,
      metadata: WORKFLOW_ID,
    });
    expect(call).toEqual({from: FORWARDER, args: [WORKFLOW_ID, PERFORM_DATA]});
  });

  test('returns null and logs when the estimate reverts', () => {
    EvmMock.testInstance(CHAIN_SELECTOR).estimateGas = () => {
      throw new Error('NoActionCanBePerformed');
    };
    const runtime = newTestRuntime();
    expect(estimateOnReport(runtime, evmClient(), RECEIVER, PERFORM_DATA, LABEL)).toBeNull();
    expect(runtime.getLogs().some((l) => l.includes('estimateGas failed'))).toBe(true);
  });
});

describe('fitsWriteQuota', () => {
  test('adds the forwarder overhead and the 1/64 it keeps back', () => {
    expect(requiredWriteGas(63_000n)).toBe(64_000n + WRITE_OVERHEAD_GAS);
  });

  test('accepts up to the largest estimate that fits MAX_WRITE_GAS', () => {
    expect(fitsWriteQuota(MAX_ESTIMATE)).toBe(true);
    expect(fitsWriteQuota(MAX_ESTIMATE + 1n)).toBe(false);
  });

  test('checks against a custom gas limit', () => {
    expect(fitsWriteQuota(63_000n, 64_000n + WRITE_OVERHEAD_GAS)).toBe(true);
    expect(fitsWriteQuota(63_001n, 64_000n + WRITE_OVERHEAD_GAS)).toBe(false);
  });
});

describe('submitReport', () => {
  test('writes the report to the receiver with the DON default gas limit and returns the tx hash', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.estimateGas = () => ({gas: ETHEREUM_MAX_ESTIMATE});
    let write: WriteReportInput | undefined;
    evmMock.writeReport = (req: WriteReportInput) => {
      write = req;
      return success();
    };

    expect(submitReport(newTestRuntime(), evmClient(), RECEIVER, PERFORM_DATA, LABEL)).toBe(
      TX_HASH,
    );
    expect(bytesToHex(write!.receiver)).toBe(RECEIVER);
    expect(write!.gasConfig).toBeUndefined();
  });

  test('estimates as `from` with `metadata` and writes with a custom gas limit', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    let from: Hex | undefined;
    evmMock.estimateGas = (req: EstimateGasInput) => {
      from = bytesToHex(req.msg.from);
      return {gas: 1n};
    };
    let gasLimit: bigint | undefined;
    evmMock.writeReport = (req: WriteReportInput) => {
      gasLimit = BigInt(req.gasConfig!.gasLimit);
      return success();
    };

    submitReport(newTestRuntime(), evmClient(), RECEIVER, PERFORM_DATA, LABEL, {
      from: FORWARDER,
      metadata: WORKFLOW_ID,
      gasLimit: 5_000_000n,
    });
    expect(from).toBe(FORWARDER);
    expect(gasLimit).toBe(5_000_000n);
  });

  test('skips the write when the estimate reverts', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.estimateGas = () => {
      throw new Error('stale');
    };
    let written = false;
    evmMock.writeReport = () => {
      written = true;
      return success();
    };

    expect(submitReport(newTestRuntime(), evmClient(), RECEIVER, PERFORM_DATA, LABEL)).toBeNull();
    expect(written).toBe(false);
  });

  test('skips the write and logs when the estimate exceeds the quota', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.estimateGas = () => ({gas: ETHEREUM_MAX_ESTIMATE + 1n});
    let written = false;
    evmMock.writeReport = () => {
      written = true;
      return success();
    };

    const runtime = newTestRuntime();
    expect(submitReport(runtime, evmClient(), RECEIVER, PERFORM_DATA, LABEL)).toBeNull();
    expect(written).toBe(false);
    expect(runtime.getLogs().some((l) => l.includes('exceeds max write gas'))).toBe(true);
  });

  test('applies the default quota on chains Chainlink did not raise', () => {
    const avalanche = 'avalanche-mainnet';
    const evmMock = EvmMock.testInstance(chainSelectorOf(avalanche));
    evmMock.estimateGas = () => ({gas: MAX_ESTIMATE + 1n});
    let written = false;
    evmMock.writeReport = () => {
      written = true;
      return success();
    };

    const client = getEvmClient({chainName: avalanche})!;
    expect(submitReport(newTestRuntime(), client, RECEIVER, PERFORM_DATA, LABEL)).toBeNull();
    expect(written).toBe(false);
  });

  test('returns null and logs when the tx fails', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.estimateGas = () => ({gas: 1n});
    evmMock.writeReport = () => ({txStatus: TxStatus.REVERTED, errorMessage: 'out of gas'});

    const runtime = newTestRuntime();
    expect(submitReport(runtime, evmClient(), RECEIVER, PERFORM_DATA, LABEL)).toBeNull();
    expect(runtime.getLogs().some((l) => l.includes('out of gas'))).toBe(true);
  });

  test('returns null and logs when the tx has no hash', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.estimateGas = () => ({gas: 1n});
    evmMock.writeReport = () => ({txStatus: TxStatus.SUCCESS, txHash: new Uint8Array()});

    const runtime = newTestRuntime();
    expect(submitReport(runtime, evmClient(), RECEIVER, PERFORM_DATA, LABEL)).toBeNull();
    expect(runtime.getLogs().some((l) => l.includes('no txHash'))).toBe(true);
  });

  test('returns null and logs when onReport reverts inside the forwarder tx', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.estimateGas = () => ({gas: 1n});
    evmMock.writeReport = () => ({
      ...success(),
      receiverContractExecutionStatus: EVM_PB.ReceiverContractExecutionStatus.REVERTED,
    });

    const runtime = newTestRuntime();
    expect(submitReport(runtime, evmClient(), RECEIVER, PERFORM_DATA, LABEL)).toBeNull();
    expect(runtime.getLogs().some((l) => l.includes(`onReport reverted in tx ${TX_HASH}`))).toBe(
      true,
    );
  });
});
