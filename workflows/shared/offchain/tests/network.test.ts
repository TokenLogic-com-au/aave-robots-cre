import {describe, expect} from 'bun:test';
import {cre} from '@chainlink/cre-sdk';
import {newTestRuntime, test} from '@chainlink/cre-sdk/test';

import {GOVERNANCE_SCHEDULE, MAX_WRITE_GAS} from '../constants';
import {
  createNetworkHandler,
  deployedNetworks,
  getEvmClient,
  initCronWorkflow,
  maxWriteGas,
} from '../network';
import {chainSelectorOf} from '../testing/mocks';

const RECEIVER = '0x1111111111111111111111111111111111111111';
const MAINNET = {chainName: 'ethereum-mainnet', isTestnet: false, receiver: RECEIVER};
const UNKNOWN = {chainName: 'not-a-chain', isTestnet: false, receiver: RECEIVER};

describe('getEvmClient', () => {
  test('returns a client for a known network', () => {
    expect(getEvmClient(MAINNET)).not.toBeNull();
  });

  test('returns null for an unknown network', () => {
    expect(getEvmClient(UNKNOWN)).toBeNull();
  });
});

describe('maxWriteGas', () => {
  test('uses the raised quota on Ethereum', () => {
    expect(maxWriteGas(getEvmClient(MAINNET)!)).toBe(16_777_216n);
  });

  test('uses the default quota on other chains', () => {
    const avalanche = getEvmClient({chainName: 'avalanche-mainnet'})!;
    expect(maxWriteGas(avalanche)).toBe(MAX_WRITE_GAS);
  });

  test('uses the default quota for a client built elsewhere', () => {
    const evmClient = new cre.capabilities.EVMClient(chainSelectorOf('ethereum-mainnet'));
    expect(maxWriteGas(evmClient)).toBe(MAX_WRITE_GAS);
  });
});

describe('deployedNetworks', () => {
  test('keeps networks with a chain name and a receiver', () => {
    const undeployed = {...MAINNET, chainName: 'polygon-mainnet', receiver: ''};
    const unnamed = {...MAINNET, chainName: ''};
    expect(deployedNetworks([MAINNET, undeployed, unnamed])).toEqual([MAINNET]);
  });
});

describe('createNetworkHandler', () => {
  test('runs with the network client and the trigger payload', () => {
    let payload: unknown;
    const handle = createNetworkHandler(MAINNET, 'label', (_runtime, evmClient, p) => {
      expect(evmClient).toBeDefined();
      payload = p;
      return 'done';
    });

    expect(handle(newTestRuntime(), 'payload')).toBe('done');
    expect(payload).toBe('payload');
  });

  test('returns "Network not found" and logs for an unknown network', () => {
    let ran = false;
    const handle = createNetworkHandler(UNKNOWN, 'label', () => {
      ran = true;
      return 'done';
    });

    const runtime = newTestRuntime();
    expect(handle(runtime, undefined)).toBe('Network not found');
    expect(ran).toBe(false);
    expect(runtime.getLogs().some((l) => l.includes('[label] network not found'))).toBe(true);
  });

  test('returns "Processing failed" and logs when the run throws', () => {
    const handle = createNetworkHandler(MAINNET, 'label', () => {
      throw new Error('boom');
    });

    const runtime = newTestRuntime();
    expect(handle(runtime, undefined)).toBe('Processing failed');
    expect(runtime.getLogs().some((l) => l.includes('[label] failed: Error: boom'))).toBe(true);
  });
});

describe('initCronWorkflow', () => {
  const config = {
    schedule: GOVERNANCE_SCHEDULE,
    evms: [MAINNET, {...MAINNET, chainName: 'polygon-mainnet', receiver: ''}],
  };

  test('registers one cron handler per deployed network on the config schedule', () => {
    const handlers = initCronWorkflow(config, () => () => 'ok');
    expect(handlers).toHaveLength(1);
    expect(handlers[0].trigger.config.schedule).toBe(GOVERNANCE_SCHEDULE);
  });

  test('registers every handler returned for a network', () => {
    const seen: string[] = [];
    const handlers = initCronWorkflow(config, (network) => {
      seen.push(network.receiver);
      return [() => 'a', () => 'b'];
    });
    expect(handlers).toHaveLength(2);
    expect(seen).toEqual([RECEIVER]);
  });
});
