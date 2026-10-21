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
  fitsWriteGasQuota,
  initWorkflow,
} from './workflow';
import productionConfig from './config.production.json';

const CHAIN_NAME = 'avalanche-mainnet';
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

// Largest estimate that still fits the write gas limit with the forwarder margin.
const MAX_ESTIMATE = ((MAX_WRITE_GAS - WRITE_OVERHEAD_GAS) * 63n) / 64n;

// Mocks a pending injection estimated at `gas`, recording each write's receiver and gas limit.
function pendingInjection(gas: bigint) {
  const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
  evmMock.callContract = checkUpkeepMock(true);
  evmMock.estimateGas = () => ({gas});
  const writes: {receiver: Hex; gasLimit?: bigint}[] = [];
  evmMock.writeReport = (input) => {
    writes.push({receiver: bytesToHex(input.receiver), gasLimit: input.gasConfig?.gasLimit});
    return {txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)};
  };
  return writes;
}

const WRITTEN = [{receiver: RECEIVER, gasLimit: MAX_WRITE_GAS}];

const handle = createReceiverHandler(NETWORK);

describe('cap-agent workflow', () => {
  test('returns "No injection needed" when checkUpkeep is false', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(false, '0x');

    expect(handle(newTestRuntime() as never)).toBe('No injection needed');
  });

  test('sends empty checkData', () => {
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

  test('returns "No injection needed" when checkUpkeep returns empty data', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = () => ({data: new Uint8Array(0)});

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('No injection needed');
    expect(runtime.getLogs().find((l) => l.includes('returned empty data'))).toBeDefined();
  });

  test('returns "No injection needed" and logs when checkUpkeep reverts', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = () => {
      throw new Error('checkUpkeep reverted');
    };

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('No injection needed');
    expect(
      runtime.getLogs().find((l) => l.includes('checkUpkeep reverted — skipping')),
    ).toBeDefined();
  });

  test('returns "submit skipped" without writing when estimateGas reverts', () => {
    const writes = pendingInjection(0n);
    EvmMock.testInstance(CHAIN_SELECTOR).estimateGas = () => {
      throw new Error('NoActionCanBePerformed');
    };

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('submit skipped');
    expect(writes.length).toBe(0);
    expect(runtime.getLogs().find((l) => l.includes('estimateGas failed'))).toBeDefined();
  });

  test('estimates onReport with the checkUpkeep performData', () => {
    pendingInjection(100_000n);
    let estimated: Hex | undefined;
    EvmMock.testInstance(CHAIN_SELECTOR).estimateGas = (req) => {
      const {functionName, args} = decodeFunctionData({
        abi: IAaveCREReceiverABI,
        data: bytesToHex(req.msg!.data),
      });
      expect(functionName).toBe('onReport');
      estimated = args?.[1] as Hex;
      return {gas: 100_000n};
    };

    handle(newTestRuntime() as never);
    expect(estimated).toBe(PERFORM_DATA);
  });

  test('skips and logs a write that does not fit the quota with the forwarder margin', () => {
    const writes = pendingInjection(MAX_ESTIMATE + 64n);

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('submit skipped: gas above quota');
    expect(writes.length).toBe(0);
    expect(
      runtime.getLogs().find((l) => l.includes('exceeds the CRE write gas quota')),
    ).toBeDefined();
  });

  test('submits the largest estimate that fits the quota with the forwarder margin', () => {
    const writes = pendingInjection(MAX_ESTIMATE);

    expect(handle(newTestRuntime() as never)).toBe(`injected, tx=${TX_HASH}`);
    expect(writes).toEqual(WRITTEN);
  });

  test('fitsWriteGasQuota adds 1/63 and the forwarder overhead to the estimate', () => {
    expect(MAX_WRITE_GAS).toBe(16_777_216n);
    expect(WRITE_OVERHEAD_GAS).toBe(250_000n);
    expect(fitsWriteGasQuota(MAX_ESTIMATE)).toBe(true);
    expect(fitsWriteGasQuota(MAX_ESTIMATE + 64n)).toBe(false);
    expect(fitsWriteGasQuota(MAX_WRITE_GAS - WRITE_OVERHEAD_GAS)).toBe(false);
  });

  test('writes to the receiver with the quota as gas limit and returns the tx hash', () => {
    const writes = pendingInjection(100_000n);

    expect(handle(newTestRuntime() as never)).toBe(`injected, tx=${TX_HASH}`);
    expect(writes).toEqual(WRITTEN);
  });

  test('returns "submit skipped" and logs when onReport reverted in the forwarder tx', () => {
    pendingInjection(100_000n);
    EvmMock.testInstance(CHAIN_SELECTOR).writeReport = () => ({
      txStatus: TxStatus.SUCCESS,
      receiverContractExecutionStatus: EVM_PB.ReceiverContractExecutionStatus.REVERTED,
      txHash: hexToBytes(TX_HASH),
    });

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('submit skipped');
    expect(runtime.getLogs().find((l) => l.includes('onReport reverted'))).toBeDefined();
  });

  test('returns "submit skipped" and logs when writeReport is not SUCCESS', () => {
    pendingInjection(100_000n);
    EvmMock.testInstance(CHAIN_SELECTOR).writeReport = () => ({
      txStatus: TxStatus.REVERTED,
      txHash: new Uint8Array(0),
      errorMessage: 'reverted',
    });

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('submit skipped');
    expect(runtime.getLogs().find((l) => l.includes('writeReport status='))).toBeDefined();
  });

  test('returns "submit skipped" and logs when writeReport has no tx hash', () => {
    pendingInjection(100_000n);
    EvmMock.testInstance(CHAIN_SELECTOR).writeReport = () => ({
      txStatus: TxStatus.SUCCESS,
      txHash: new Uint8Array(0),
    });

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('submit skipped');
    expect(runtime.getLogs().find((l) => l.includes('no txHash'))).toBeDefined();
  });

  test('returns "Network not found" for an unknown chain', () => {
    const badHandle = createReceiverHandler({...NETWORK, chainName: 'made-up-chain'});
    expect(badHandle(newTestRuntime() as never)).toBe('Network not found');
  });
});

describe('initWorkflow', () => {
  test('creates one cron handler per network with a receiver', () => {
    const handlers = initWorkflow({
      schedule: '*/5 * * * *',
      evms: [NETWORK, {...NETWORK, chainName: 'polygon-mainnet'}],
    }) as unknown as {trigger: {config: Record<string, unknown>}}[];
    expect(handlers.length).toBe(2);
    expect(handlers[0].trigger.config.schedule).toBe('*/5 * * * *');
  });

  test('skips networks with empty receiver', () => {
    const handlers = initWorkflow({schedule: '* * * * *', evms: [{...NETWORK, receiver: ''}]});
    expect(handlers.length).toBe(0);
  });

  test('every production chain is a known CRE network', () => {
    const config = configSchema.parse(productionConfig);
    for (const net of config.evms) {
      const network = getNetwork({
        chainFamily: 'evm',
        chainSelectorName: net.chainName,
        isTestnet: net.isTestnet,
      });
      expect(network).toBeDefined();
    }
  });

  // CRE caps triggers per workflow at 10 (PerWorkflow.TriggerSubscriptionLimit).
  test('production config stays within the CRE trigger limit', () => {
    const config = configSchema.parse(productionConfig);
    const evms = config.evms.map((net) => ({...net, receiver: RECEIVER}));
    expect(initWorkflow({...config, evms}).length).toBeLessThanOrEqual(10);
  });
});
