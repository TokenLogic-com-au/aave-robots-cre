import {describe, expect} from 'bun:test';
import {TxStatus} from '@chainlink/cre-sdk';
import {EvmMock, newTestRuntime, test} from '@chainlink/cre-sdk/test';
import {bytesToHex, decodeFunctionData, hexToBytes, type Hex} from 'viem';

import {IAaveCREReceiverABI} from '../../shared/offchain/abi/IAaveCREReceiver';
import {GOVERNANCE_SCHEDULE} from '../../shared/offchain/constants';
import {
  chainSelectorOf,
  checkUpkeepMock,
  encodeCheckUpkeepResult,
  type CallContractInput,
} from '../../shared/offchain/testing/mocks';
import {configSchema, createReceiverHandler, initWorkflow} from './workflow';
import productionConfig from './config.production.json';

const VOTING_CHAINS = ['ethereum-mainnet', 'avalanche-mainnet', 'polygon-mainnet'];

const CHAIN_NAME = 'ethereum-mainnet';
const CHAIN_SELECTOR = chainSelectorOf(CHAIN_NAME);

const RECEIVER = '0x1111111111111111111111111111111111111111' as Hex;
const TX_HASH = ('0xab' + 'cd'.repeat(31)) as Hex;
// The workflow passes performData through unchanged, so any non-empty payload works.
const PERFORM_DATA = '0xdeadbeef' as Hex;

const handle = createReceiverHandler({chainName: CHAIN_NAME, isTestnet: false, receiver: RECEIVER});

describe('voting-chain-robot workflow', () => {
  test('calls checkUpkeep on the receiver with empty checkData', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    let to: Hex | undefined;
    let checkData: Hex | undefined;
    evmMock.callContract = (req: CallContractInput) => {
      to = bytesToHex(req.call.to);
      return checkUpkeepMock(false, '0x', (data) => (checkData = data))(req);
    };

    expect(handle(newTestRuntime() as never)).toBe('No action needed');
    expect(to).toBe(RECEIVER);
    expect(checkData).toBe('0x');
  });

  test('estimates and writes onReport with the checkUpkeep performData to the receiver', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true, PERFORM_DATA);
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

  test('returns "submit skipped" without writing when onReport would revert', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true, PERFORM_DATA);
    evmMock.estimateGas = () => {
      throw new Error('NoActionCanBePerformed');
    };
    let written = false;
    evmMock.writeReport = () => {
      written = true;
      return {txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)};
    };

    expect(handle(newTestRuntime() as never)).toBe('submit skipped');
    expect(written).toBe(false);
  });
});

describe('initWorkflow', () => {
  test('production config covers the three voting chains on the governance schedule', () => {
    const config = configSchema.parse(productionConfig);
    expect(config.schedule).toBe(GOVERNANCE_SCHEDULE);
    expect(config.evms.map((net) => net.chainName)).toEqual(VOTING_CHAINS);
    config.evms.forEach((net) => expect(chainSelectorOf(net.chainName)).toBeDefined());
  });

  test('creates one handler per voting chain, each calling its own receiver on its chain', () => {
    const receivers = VOTING_CHAINS.map((_, i) => `0x${String(i + 1).repeat(40)}` as Hex);
    const handlers = initWorkflow({
      schedule: GOVERNANCE_SCHEDULE,
      evms: VOTING_CHAINS.map((chainName, i) => ({
        chainName,
        isTestnet: false,
        receiver: receivers[i],
      })),
    }) as unknown as {fn: (runtime: never, payload: unknown) => string}[];
    expect(handlers.length).toBe(VOTING_CHAINS.length);

    const called: string[] = [];
    VOTING_CHAINS.forEach((chainName) => {
      EvmMock.testInstance(chainSelectorOf(chainName)).callContract = (req: CallContractInput) => {
        called.push(`${chainName}:${bytesToHex(req.call.to)}`);
        return {data: encodeCheckUpkeepResult(false, '0x')};
      };
    });
    handlers.forEach((h) => h.fn(newTestRuntime() as never, {}));
    expect(called).toEqual(VOTING_CHAINS.map((chainName, i) => `${chainName}:${receivers[i]}`));
  });
});
