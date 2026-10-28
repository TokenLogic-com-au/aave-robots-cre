import {describe, expect} from 'bun:test';
import {TxStatus, getNetwork} from '@chainlink/cre-sdk';
import {EvmMock, newTestRuntime, test} from '@chainlink/cre-sdk/test';
import {bytesToHex, decodeFunctionData, hexToBytes, type Hex} from 'viem';

import {IAaveCREReceiverABI} from '../../shared/offchain/abi/IAaveCREReceiver';
import {GOVERNANCE_SCHEDULE} from '../../shared/offchain/constants';
import {maxWriteGasOf} from '../../shared/offchain/network';
import {chainSelectorOf, checkUpkeepMock} from '../../shared/offchain/testing/mocks';
import {
  configSchema,
  createReceiverHandler,
  decodePayloadIds,
  encodePayloadIds,
  initWorkflow,
} from './workflow';
import productionConfig from './config.production.json';

const CHAIN_NAME = 'ethereum-mainnet';
const CHAIN_SELECTOR = chainSelectorOf(CHAIN_NAME);

const RECEIVER = '0x1111111111111111111111111111111111111111' as Hex;
const TX_HASH = ('0xab' + 'cd'.repeat(31)) as Hex;

const NETWORK = {chainName: CHAIN_NAME, isTestnet: false, receiver: RECEIVER};

type EstimateGasInput = {msg?: {data: Uint8Array}};

function payloadsMock(ids: number[]) {
  return checkUpkeepMock(ids.length > 0, ids.length > 0 ? encodePayloadIds(ids) : '0x');
}

// The payload ids of the onReport call being estimated.
function estimatedIds(input: EstimateGasInput): readonly number[] {
  const {args} = decodeFunctionData({abi: IAaveCREReceiverABI, data: bytesToHex(input.msg!.data)});
  return decodePayloadIds(args![1] as Hex);
}

const success = () => ({txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)});

const handle = createReceiverHandler(NETWORK);

describe('execution-chain-robot workflow', () => {
  test('returns "No payload to execute" when checkUpkeep is false, sending empty checkData', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    let checkData: Hex | undefined;
    evmMock.callContract = checkUpkeepMock(false, '0x', (data) => (checkData = data));

    expect(handle(newTestRuntime() as never)).toBe('No payload to execute');
    expect(checkData).toBe('0x');
  });

  test('writes one report per payload, in checkUpkeep order', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = payloadsMock([7, 9]);
    const estimated: (readonly number[])[] = [];
    evmMock.estimateGas = (input: EstimateGasInput) => {
      estimated.push(estimatedIds(input));
      return {gas: 100_000n};
    };
    let receiver: Hex | undefined;
    evmMock.writeReport = (input) => {
      receiver = bytesToHex(input.receiver);
      return success();
    };

    expect(handle(newTestRuntime() as never)).toBe(`executed 7:${TX_HASH}, 9:${TX_HASH}`);
    expect(estimated).toEqual([[7], [9]]);
    expect(receiver).toBe(RECEIVER);
  });

  test('skips and logs a payload that does not fit the write quota, still executing the rest', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = payloadsMock([7, 9]);
    evmMock.estimateGas = (input: EstimateGasInput) => ({
      gas: estimatedIds(input)[0] === 7 ? maxWriteGasOf(CHAIN_NAME) : 100_000n,
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
    evmMock.callContract = payloadsMock([7, 9]);
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
    evmMock.callContract = payloadsMock([7]);
    evmMock.estimateGas = () => ({gas: maxWriteGasOf(CHAIN_NAME)});
    let written = false;
    evmMock.writeReport = () => {
      written = true;
      return success();
    };

    expect(handle(newTestRuntime() as never)).toBe('submit skipped');
    expect(written).toBe(false);
  });
});

describe('production config', () => {
  // CRE caps triggers per workflow at 10 (PerWorkflow.TriggerSubscriptionLimit).
  test('is valid, runs on the governance schedule and stays within the CRE trigger limit', () => {
    const config = configSchema.parse(productionConfig);
    expect(config.schedule).toBe(GOVERNANCE_SCHEDULE);
    for (const net of config.evms) {
      expect(
        getNetwork({chainFamily: 'evm', chainSelectorName: net.chainName, isTestnet: false}),
      ).toBeDefined();
    }
    const evms = config.evms.map((net) => ({...net, receiver: RECEIVER}));
    expect(initWorkflow({...config, evms}).length).toBeLessThanOrEqual(10);
  });
});
