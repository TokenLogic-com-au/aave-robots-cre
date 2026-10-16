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
import {
  MAX_WRITE_GAS,
  configSchema,
  createReceiverHandler,
  decodePayloadIds,
  encodePayloadIds,
  initWorkflow,
} from './workflow';
import productionConfig from './config.production.json';

const CHAIN_NAME = 'ethereum-mainnet';
const CHAIN_SELECTOR = getNetwork({
  chainFamily: 'evm',
  chainSelectorName: CHAIN_NAME,
  isTestnet: false,
})!.chainSelector.selector;

const RECEIVER = '0x1111111111111111111111111111111111111111' as Hex;
const TX_HASH = ('0xab' + 'cd'.repeat(31)) as Hex;

const NETWORK = {chainName: CHAIN_NAME, isTestnet: false, receiver: RECEIVER};

type EstimateGasInput = {msg?: {data: Uint8Array}};

// Mocks callContract for a single checkUpkeep call, returning the given payload ids.
function checkUpkeepMock(upkeepNeeded: boolean, ids: number[] = []) {
  return (req: CallContractInput): {data: Uint8Array} => {
    const selector = bytesToHex(req.call.data).slice(0, 10).toLowerCase();
    if (selector === CHECK_UPKEEP_SELECTOR) {
      return {
        data: encodeCheckUpkeepResult(upkeepNeeded, upkeepNeeded ? encodePayloadIds(ids) : '0x'),
      };
    }
    throw new Error(`checkUpkeepMock: unmocked selector ${selector}`);
  };
}

// The payload ids of the onReport call being estimated.
function estimatedIds(input: EstimateGasInput): readonly number[] {
  const {args} = decodeFunctionData({abi: IAaveCREReceiverABI, data: bytesToHex(input.msg!.data)});
  return decodePayloadIds(args![1] as Hex);
}

const success = () => ({txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)});

const handle = createReceiverHandler(NETWORK);

describe('execution-chain-robot workflow', () => {
  test('returns "No payload to execute" when checkUpkeep is false', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(false);

    expect(handle(newTestRuntime() as never)).toBe('No payload to execute');
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

  test('returns "No payload to execute" and logs when checkUpkeep reverts', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = () => {
      throw new Error('checkUpkeep reverted');
    };

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('No payload to execute');
    expect(
      runtime.getLogs().find((l) => l.includes('checkUpkeep reverted — skipping')),
    ).toBeDefined();
  });

  test('writes one report per payload, in checkUpkeep order, requesting the full quota', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true, [7, 9]);
    const estimated: (readonly number[])[] = [];
    evmMock.estimateGas = (input: EstimateGasInput) => {
      estimated.push(estimatedIds(input));
      return {gas: 100_000n};
    };
    const gasLimits: (bigint | undefined)[] = [];
    let receiver: Hex | undefined;
    evmMock.writeReport = (input) => {
      gasLimits.push(input.gasConfig?.gasLimit);
      receiver = bytesToHex(input.receiver);
      return success();
    };

    expect(handle(newTestRuntime() as never)).toBe(`executed 7:${TX_HASH}, 9:${TX_HASH}`);
    expect(estimated).toEqual([[7], [9]]);
    expect(gasLimits).toEqual([MAX_WRITE_GAS, MAX_WRITE_GAS]);
    expect(receiver).toBe(RECEIVER);
  });

  test('skips and logs a payload estimated above the write quota, still executing the rest', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true, [7, 9]);
    evmMock.estimateGas = (input: EstimateGasInput) => ({
      gas: estimatedIds(input)[0] === 7 ? MAX_WRITE_GAS + 1n : MAX_WRITE_GAS,
    });
    let writes = 0;
    evmMock.writeReport = () => {
      writes++;
      return success();
    };

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe(`executed 9:${TX_HASH}`);
    expect(writes).toBe(1);
    expect(
      runtime.getLogs().find((l) => l.includes('payload 7') && l.includes('exceeds max write gas')),
    ).toBeDefined();
  });

  test('skips a payload whose estimate reverts, still executing the rest', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true, [7, 9]);
    evmMock.estimateGas = (input: EstimateGasInput) => {
      if (estimatedIds(input)[0] === 9) throw new Error('reverted');
      return {gas: 100_000n};
    };
    evmMock.writeReport = success;

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe(`executed 7:${TX_HASH}`);
    expect(
      runtime.getLogs().find((l) => l.includes('payload 9') && l.includes('estimateGas failed')),
    ).toBeDefined();
  });

  test('returns "submit skipped" when every payload is skipped', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true, [7]);
    evmMock.estimateGas = () => ({gas: MAX_WRITE_GAS + 1n});
    let written = false;
    evmMock.writeReport = () => {
      written = true;
      return success();
    };

    expect(handle(newTestRuntime() as never)).toBe('submit skipped');
    expect(written).toBe(false);
  });

  test('returns "submit skipped" and logs when writeReport is not SUCCESS', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true, [7]);
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

describe('initWorkflow', () => {
  test('creates one handler per network with a receiver', () => {
    const handlers = initWorkflow({
      schedule: '* * * * *',
      evms: [NETWORK, {...NETWORK, chainName: 'avalanche-mainnet'}, {...NETWORK, receiver: ''}],
    });
    expect(handlers.length).toBe(2);
  });

  // CRE caps triggers per workflow at 10 (PerWorkflow.TriggerSubscriptionLimit).
  test('production config is valid and stays within the CRE trigger limit', () => {
    const config = configSchema.parse(productionConfig);
    for (const net of config.evms) {
      expect(
        getNetwork({chainFamily: 'evm', chainSelectorName: net.chainName, isTestnet: false}),
      ).toBeDefined();
    }
    const evms = config.evms.map((net) => ({...net, receiver: RECEIVER}));
    expect(initWorkflow({...config, evms}).length).toBeLessThanOrEqual(10);
  });
});
