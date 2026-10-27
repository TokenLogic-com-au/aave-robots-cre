import {describe, expect} from 'bun:test';
import {getNetwork, TxStatus} from '@chainlink/cre-sdk';
import {EvmMock, newTestRuntime, test} from '@chainlink/cre-sdk/test';
import {bytesToHex, decodeFunctionData, hexToBytes, type Hex} from 'viem';

import {IAaveCREReceiverABI} from '../../shared/offchain/abi/IAaveCREReceiver';
import {MAX_WRITE_GAS} from '../../shared/offchain/constants';
import {chainSelectorOf, checkUpkeepMock} from '../../shared/offchain/testing/mocks';
import {configSchema, initWorkflow} from './workflow';
import productionConfig from './config.production.json';

// CRE caps triggers per workflow (PerWorkflow.TriggerSubscriptionLimit).
const MAX_TRIGGERS = 10;

const CHAIN_NAME = 'avalanche-mainnet';
const CHAIN_SELECTOR = chainSelectorOf(CHAIN_NAME);
const SCHEDULE = '*/5 * * * *';

const RECEIVER = '0x1111111111111111111111111111111111111111' as Hex;
const TX_HASH = ('0xab' + 'cd'.repeat(31)) as Hex;
// The workflow treats performData as opaque (it only signs it), so any non-empty payload works.
const PERFORM_DATA = '0xdeadbeef' as Hex;

const NETWORK = {chainName: CHAIN_NAME, isTestnet: false, receiver: RECEIVER};

function handle(runtime = newTestRuntime(), network = NETWORK): string {
  const [entry] = initWorkflow({schedule: SCHEDULE, evms: [network]});
  return entry.fn(runtime as never, undefined as never);
}

// Mocks a pending injection estimated at 100k gas, recording each write.
function pendingInjection() {
  const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
  evmMock.callContract = checkUpkeepMock(true, PERFORM_DATA);
  evmMock.estimateGas = () => ({gas: 100_000n});
  const writes: {receiver: Hex; gasLimit?: string}[] = [];
  evmMock.writeReport = (input) => {
    writes.push({
      receiver: bytesToHex(input.receiver),
      gasLimit: input.gasConfig?.gasLimit?.toString(),
    });
    return {txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)};
  };
  return writes;
}

describe('cap-agent workflow', () => {
  test('sends empty checkData and returns "No injection needed" when checkUpkeep is false', () => {
    let checkData: Hex | undefined;
    EvmMock.testInstance(CHAIN_SELECTOR).callContract = checkUpkeepMock(
      false,
      '0x',
      (d) => (checkData = d),
    );

    expect(handle()).toBe('No injection needed');
    expect(checkData).toBe('0x');
  });

  test('returns "No injection needed" when checkUpkeep reverts', () => {
    EvmMock.testInstance(CHAIN_SELECTOR).callContract = () => {
      throw new Error('checkUpkeep reverted');
    };

    expect(handle()).toBe('No injection needed');
  });

  test('returns "submit skipped" without writing when estimateGas reverts', () => {
    const writes = pendingInjection();
    EvmMock.testInstance(CHAIN_SELECTOR).estimateGas = () => {
      throw new Error('NoActionCanBePerformed');
    };

    expect(handle()).toBe('submit skipped');
    expect(writes.length).toBe(0);
  });

  test('estimates and writes the checkUpkeep performData to the receiver', () => {
    const writes = pendingInjection();
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

    expect(handle()).toBe(`injected, tx=${TX_HASH}`);
    expect(estimated).toBe(PERFORM_DATA);
    expect(writes).toEqual([{receiver: RECEIVER, gasLimit: MAX_WRITE_GAS.toString()}]);
  });

  test('returns "submit skipped" when the write fails', () => {
    pendingInjection();
    EvmMock.testInstance(CHAIN_SELECTOR).writeReport = () => ({
      txStatus: TxStatus.REVERTED,
      txHash: new Uint8Array(0),
      errorMessage: 'reverted',
    });

    expect(handle()).toBe('submit skipped');
  });

  test('returns "Network not found" for an unknown chain', () => {
    expect(handle(newTestRuntime(), {...NETWORK, chainName: 'made-up-chain'})).toBe(
      'Network not found',
    );
  });
});

describe('initWorkflow', () => {
  test('creates one cron handler per network with a receiver', () => {
    const handlers = initWorkflow({
      schedule: SCHEDULE,
      evms: [NETWORK, {...NETWORK, chainName: 'polygon-mainnet'}],
    });
    expect(handlers.length).toBe(2);
    expect(handlers[0].trigger.config.schedule).toBe(SCHEDULE);
  });

  test('skips networks with empty receiver', () => {
    expect(initWorkflow({schedule: SCHEDULE, evms: [{...NETWORK, receiver: ''}]}).length).toBe(0);
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

  test('production config stays within the CRE trigger limit', () => {
    const config = configSchema.parse(productionConfig);
    const evms = config.evms.map((net) => ({...net, receiver: RECEIVER}));
    expect(initWorkflow({...config, evms}).length).toBeLessThanOrEqual(MAX_TRIGGERS);
  });
});
