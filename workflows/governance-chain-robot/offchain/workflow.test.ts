import {describe, expect} from 'bun:test';
import {TxStatus} from '@chainlink/cre-sdk';
import {EvmMock, newTestRuntime, test} from '@chainlink/cre-sdk/test';
import {bytesToHex, decodeFunctionData, hexToBytes, type Hex} from 'viem';

import {IAaveCREReceiverABI} from '../../shared/offchain/abi/IAaveCREReceiver';
import {GOVERNANCE_SCHEDULE, MAX_WRITE_GAS} from '../../shared/offchain/constants';
import {chainSelectorOf, checkUpkeepMock} from '../../shared/offchain/testing/mocks';
import productionConfig from './config.production.json';
import {configSchema, createReceiverHandler, initWorkflow} from './workflow';

const CHAIN_NAME = 'ethereum-mainnet';
const CHAIN_SELECTOR = chainSelectorOf(CHAIN_NAME);

const RECEIVER = '0x1111111111111111111111111111111111111111' as Hex;
const TX_HASH = ('0xab' + 'cd'.repeat(31)) as Hex;
// The workflow treats performData as opaque (it only signs it), so any non-empty payload works.
const PERFORM_DATA = '0xdeadbeef' as Hex;

const NETWORK = {chainName: CHAIN_NAME, isTestnet: false, receiver: RECEIVER};

type EstimateGasInput = {msg: {to: Uint8Array; data: Uint8Array}};

const handle = createReceiverHandler(NETWORK);

describe('governance chain robot workflow', () => {
  test('calls checkUpkeep with empty checkData and returns "No action needed" when false', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    let checkData: Hex | undefined;
    evmMock.callContract = checkUpkeepMock(false, '0x', (data) => (checkData = data));

    expect(handle(newTestRuntime() as never)).toBe('No action needed');
    expect(checkData).toBe('0x');
  });

  test('estimates and writes the checkUpkeep performData to the receiver', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true, PERFORM_DATA);
    let estimated: {to: Hex; args: readonly unknown[] | undefined} | undefined;
    evmMock.estimateGas = (req: EstimateGasInput) => {
      const {args} = decodeFunctionData({abi: IAaveCREReceiverABI, data: bytesToHex(req.msg.data)});
      estimated = {to: bytesToHex(req.msg.to), args};
      return {gas: 100_000n};
    };
    let written: {receiver: Hex; gasLimit: bigint} | undefined;
    evmMock.writeReport = (input) => {
      written = {receiver: bytesToHex(input.receiver), gasLimit: input.gasConfig?.gasLimit};
      return {txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)};
    };

    expect(handle(newTestRuntime() as never)).toBe(`actions performed, tx=${TX_HASH}`);
    expect(estimated).toEqual({to: RECEIVER, args: ['0x', PERFORM_DATA]});
    expect(written).toEqual({receiver: RECEIVER, gasLimit: undefined});
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
  test('runs every 10 minutes in production, with no trigger until the receiver is set', () => {
    const config = configSchema.parse(productionConfig);
    expect(config.schedule).toBe(GOVERNANCE_SCHEDULE);
    expect(initWorkflow(config)).toHaveLength(0);
    expect(initWorkflow({...config, evms: [NETWORK]})).toHaveLength(1);
  });
});
