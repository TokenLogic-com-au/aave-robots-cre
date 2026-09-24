import {describe, expect} from 'bun:test';
import {addContractMock, EvmMock, test} from '@chainlink/cre-sdk/test';
import {getNetwork, TxStatus} from '@chainlink/cre-sdk';
import {
  decodeAbiParameters,
  decodeFunctionData,
  hexToBytes,
  parseAbiParameters,
  type Address,
  type Hex,
} from 'viem';

import {IAaveDataProviderV2} from './abi/IAaveDataProviderV2';
import {IAaveDepositorReceiver} from './abi/IAaveDepositorReceiver';
import {IERC20} from './abi/IERC20';
import {ISteward} from './abi/ISteward';
import {configSchema} from './types';
import {
  chunkCalls,
  initWorkflow,
  MAX_CALLS_PER_REPORT,
  MAX_REPORTS_PER_RUN,
  MAX_WRITE_GAS,
  onCronTrigger,
  withHeadroom,
} from './workflow';
import {
  ADDR,
  GAS_ESTIMATE,
  TX_HASH,
  makeRuntime,
  replyToHex,
  setupBaseEvmMocks,
} from './test-helpers/evmMocks';

const CHAIN_NAME = 'ethereum-mainnet';
const CHAIN_SELECTOR = getNetwork({
  chainFamily: 'evm',
  chainSelectorName: CHAIN_NAME,
  isTestnet: false,
})!.chainSelector.selector;

const BASE_CONFIG = {
  schedule: '0 * * * * *',
  chainName: CHAIN_NAME,
  receiver: ADDR.receiver,
  dataProviderV3: ADDR.dataProviderV3,
  collector: ADDR.collector,
  priceOracle: ADDR.priceOracle,
  corePoolV3: ADDR.corePoolV3,
  depositMinUsd: '100000000',
  migrationMinUsd: '100000000',
  migrationBps: '1000',
  ignoredTokens: [],
  primeTokens: [],
};

const V2_CONFIG = {
  ...BASE_CONFIG,
  dataProviderV2: ADDR.dataProviderV2,
  corePoolV2: ADDR.corePoolV2,
};

const ZERO = '0x0000000000000000000000000000000000000000' as Address;
const WORKFLOW_ID = `0x${'ab'.repeat(32)}` as Hex;
const SUBMITTED = `1 report(s) submitted, tx=${TX_HASH}`;

function mockV2(evmMock: EvmMock, aTokenBalance: bigint, availableLiquidity: bigint) {
  const dpV2 = addContractMock(evmMock, {address: ADDR.dataProviderV2, abi: IAaveDataProviderV2});
  dpV2.getReserveTokensAddresses = () => [ADDR.usdcATokenV2, ZERO, ZERO];
  dpV2.getReserveData = () => [availableLiquidity, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0];
  const aToken = addContractMock(evmMock, {address: ADDR.usdcATokenV2, abi: IERC20});
  aToken.balanceOf = () => aTokenBalance;
}

// Captures every batch the workflow asks the receiver to validate.
function captureChecks(receiver: ReturnType<typeof setupBaseEvmMocks>['receiver']) {
  const checked: Hex[] = [];
  receiver.checkUpkeep = (checkData: unknown) => {
    checked.push(checkData as Hex);
    return [true, checkData];
  };
  return checked;
}

function decodeCalls(checkData: Hex) {
  const [calls] = decodeAbiParameters(parseAbiParameters('bytes[]'), checkData);
  return calls.map((c) => decodeFunctionData({abi: ISteward, data: c}));
}

describe('config', () => {
  test('parses numbers to bigint and normalizes addresses', () => {
    const config = configSchema.parse({
      ...BASE_CONFIG,
      receiver: '0x249396a890F89D47F89326d7EE116b1d374fb3A9',
    });
    expect(config.depositMinUsd).toBe(100000000n);
    expect(config.receiver).toBe('0x249396a890F89D47F89326d7EE116b1d374Fb3A9');
    expect(config.dataProviderV2).toBeUndefined();
  });

  test('rejects a malformed address, a partial V2 config and migrationBps above 100%', () => {
    expect(() => configSchema.parse({...BASE_CONFIG, collector: '0x1234'})).toThrow();
    expect(() => configSchema.parse({...BASE_CONFIG, corePoolV2: ADDR.corePoolV2})).toThrow();
    expect(() => configSchema.parse({...BASE_CONFIG, migrationBps: '10001'})).toThrow();
  });
});

describe('gas and batching', () => {
  test('withHeadroom adds 25%', () => {
    expect(withHeadroom(1_000_000n)).toBe(1_250_000n);
  });

  test('chunkCalls splits into batches of MAX_CALLS_PER_REPORT', () => {
    const calls = Array.from(
      {length: MAX_CALLS_PER_REPORT * 2 + 1},
      (_, i) => `0x0${i % 10}` as Hex,
    );
    const chunks = chunkCalls(calls);
    expect(chunks.length).toBe(3);
    expect(chunks[0].length).toBe(MAX_CALLS_PER_REPORT);
    expect(chunks[2].length).toBe(1);
    expect(chunks.flat()).toEqual(calls);
  });
});

describe('initWorkflow', () => {
  test('creates one cron handler', () => {
    expect(initWorkflow(configSchema.parse(BASE_CONFIG)).length).toBe(1);
  });

  test('creates no handler without a receiver', () => {
    expect(initWorkflow(configSchema.parse({...BASE_CONFIG, receiver: ''})).length).toBe(0);
  });
});

describe('onCronTrigger deposits', () => {
  test('submits one depositV3 call into the core pool', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    const checked = captureChecks(setupBaseEvmMocks(evmMock).receiver);

    const runtime = makeRuntime(BASE_CONFIG);
    expect(onCronTrigger(runtime)).toBe(SUBMITTED);
    expect(runtime.getLogs().join('\n')).toContain('1 deposit(s) + 0 migration(s)');

    expect(checked.length).toBe(1);
    const [call] = decodeCalls(checked[0]);
    expect(call.functionName).toBe('depositV3');
    expect(call.args).toEqual([ADDR.corePoolV3, ADDR.usdc, 1000_000000n]);
  });

  test('routes prime tokens to the prime pool', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    const checked = captureChecks(setupBaseEvmMocks(evmMock).receiver);

    const config = {...BASE_CONFIG, primePoolV3: ADDR.primePoolV3, primeTokens: [ADDR.usdc]};
    expect(onCronTrigger(makeRuntime(config))).toBe(SUBMITTED);
    const [call] = decodeCalls(checked[0]);
    expect(call.args).toEqual([ADDR.primePoolV3, ADDR.usdc, 1000_000000n]);
  });

  test('skips when USD value is below depositMinUsd', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    setupBaseEvmMocks(evmMock, {usdcBalance: 500_000n});
    expect(onCronTrigger(makeRuntime(BASE_CONFIG))).toBe('No calls to execute');
  });

  test('skips when the collector balance is zero', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    setupBaseEvmMocks(evmMock, {usdcBalance: 0n});
    expect(onCronTrigger(makeRuntime(BASE_CONFIG))).toBe('No calls to execute');
  });

  test('skips ignored tokens', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    setupBaseEvmMocks(evmMock);
    expect(onCronTrigger(makeRuntime({...BASE_CONFIG, ignoredTokens: [ADDR.usdc]}))).toBe(
      'No calls to execute',
    );
  });

  test('treats a reserve whose config read fails as inactive', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    const {dpV3} = setupBaseEvmMocks(evmMock);
    dpV3.getReserveConfigurationData = () => {
      throw new Error('boom');
    };
    const runtime = makeRuntime(BASE_CONFIG);
    expect(onCronTrigger(runtime)).toBe('No calls to execute');
    expect(runtime.getLogs().join('\n')).toContain('inactive=1');
  });

  test('caps the amount to 95% of the room left under the supply cap', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    const checked = captureChecks(
      setupBaseEvmMocks(evmMock, {supplyCap: 500n, v3Supply: 0n}).receiver,
    );
    const runtime = makeRuntime(BASE_CONFIG);
    expect(onCronTrigger(runtime)).toBe(SUBMITTED);
    const [call] = decodeCalls(checked[0]);
    expect(call.args).toEqual([ADDR.corePoolV3, ADDR.usdc, 475_000000n]);
  });

  test('skips when the supply cap is reached', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    setupBaseEvmMocks(evmMock, {supplyCap: 100n, v3Supply: 100_000000n});
    const runtime = makeRuntime(BASE_CONFIG);
    expect(onCronTrigger(runtime)).toBe('No calls to execute');
    expect(runtime.getLogs().join('\n')).toContain('supply cap reached');
  });

  test('splits many calls into reports of MAX_CALLS_PER_REPORT and defers the rest', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    const total = MAX_CALLS_PER_REPORT * MAX_REPORTS_PER_RUN + 1;
    const extraTokens = Array.from({length: total - 1}, (_, i) => ({
      address: `0x2${(i + 1).toString(16).padStart(39, '0')}` as Address,
      balance: 1000_000000n,
    }));
    const checked = captureChecks(setupBaseEvmMocks(evmMock, {extraTokens}).receiver);

    const runtime = makeRuntime(BASE_CONFIG);
    const result = onCronTrigger(runtime);
    expect(result).toBe(
      `${MAX_REPORTS_PER_RUN} report(s) submitted, tx=${Array(MAX_REPORTS_PER_RUN).fill(TX_HASH).join(',')}`,
    );
    expect(checked.length).toBe(MAX_REPORTS_PER_RUN);
    expect(decodeCalls(checked[0]).length).toBe(MAX_CALLS_PER_REPORT);
    expect(runtime.getLogs().join('\n')).toContain('1 call(s) deferred to the next tick');
  });

  test('returns "submit skipped" when the receiver rejects the batch', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    const {receiver} = setupBaseEvmMocks(evmMock);
    receiver.checkUpkeep = () => [false, '0x'];
    expect(onCronTrigger(makeRuntime(BASE_CONFIG))).toBe('submit skipped');
  });

  test('estimates onReport from the forwarder with the pinned workflow id and writes with 25% headroom', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    const {receiver} = setupBaseEvmMocks(evmMock);
    receiver.expectedWorkflowId = () => WORKFLOW_ID;
    let estimateFrom: Hex | undefined;
    let metadata: Hex | undefined;
    let gasLimit: bigint | undefined;
    evmMock.estimateGas = (input) => {
      estimateFrom = replyToHex(input.msg!.from);
      const {args} = decodeFunctionData({
        abi: IAaveDepositorReceiver,
        data: replyToHex(input.msg!.data),
      });
      metadata = args![0] as Hex;
      return {gas: GAS_ESTIMATE};
    };
    evmMock.writeReport = (input) => {
      gasLimit = input.gasConfig?.gasLimit;
      return {txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)};
    };
    expect(onCronTrigger(makeRuntime(BASE_CONFIG))).toBe(SUBMITTED);
    expect(estimateFrom?.toLowerCase()).toBe(ADDR.forwarder.toLowerCase());
    expect(metadata).toBe(WORKFLOW_ID);
    expect(gasLimit).toBe(withHeadroom(GAS_ESTIMATE));
  });

  test('returns "submit skipped" when the receiver cannot be read', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    const {receiver} = setupBaseEvmMocks(evmMock);
    receiver.FORWARDER = () => {
      throw new Error('boom');
    };
    const runtime = makeRuntime(BASE_CONFIG);
    expect(onCronTrigger(runtime)).toBe('submit skipped');
    expect(runtime.getLogs().join('\n')).toContain('failed to read receiver');
  });

  test('returns "submit skipped" when estimateGas reverts', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    setupBaseEvmMocks(evmMock);
    evmMock.estimateGas = () => {
      throw new Error('execution reverted');
    };
    const runtime = makeRuntime(BASE_CONFIG);
    expect(onCronTrigger(runtime)).toBe('submit skipped');
    expect(runtime.getLogs().join('\n')).toContain('estimateGas failed');
  });

  test('returns "submit skipped" when the estimate exceeds the max write gas', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    setupBaseEvmMocks(evmMock);
    evmMock.estimateGas = () => ({gas: MAX_WRITE_GAS});
    const runtime = makeRuntime(BASE_CONFIG);
    expect(onCronTrigger(runtime)).toBe('submit skipped');
    expect(runtime.getLogs().join('\n')).toContain('exceeds max write gas');
  });

  test('returns "submit skipped" when writeReport is not SUCCESS', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    setupBaseEvmMocks(evmMock);
    evmMock.writeReport = () => ({
      txStatus: TxStatus.REVERTED,
      txHash: new Uint8Array(0),
      errorMessage: 'reverted',
    });
    const runtime = makeRuntime(BASE_CONFIG);
    expect(onCronTrigger(runtime)).toBe('submit skipped');
    expect(runtime.getLogs().find((l) => l.includes('writeReport status='))).toBeDefined();
  });

  test('returns "Network not found" for an unknown chain', () => {
    expect(onCronTrigger(makeRuntime({...BASE_CONFIG, chainName: 'made-up-chain'}))).toBe(
      'Network not found',
    );
  });
});

describe('onCronTrigger migrations', () => {
  test('submits one migrateV2toV3 call for migrationBps of the V2 balance', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    const checked = captureChecks(setupBaseEvmMocks(evmMock, {usdcBalance: 0n}).receiver);
    mockV2(evmMock, 1000_000000n, 5000_000000n);

    const runtime = makeRuntime(V2_CONFIG);
    expect(onCronTrigger(runtime)).toBe(SUBMITTED);
    expect(runtime.getLogs().join('\n')).toContain('-> Migrate');

    const [call] = decodeCalls(checked[0]);
    expect(call.functionName).toBe('migrateV2toV3');
    expect(call.args).toEqual([ADDR.corePoolV2, ADDR.corePoolV3, ADDR.usdc, 100_000000n]);
  });

  test('skips when the V2 aToken balance is zero', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    setupBaseEvmMocks(evmMock, {usdcBalance: 0n});
    mockV2(evmMock, 0n, 5000_000000n);
    expect(onCronTrigger(makeRuntime(V2_CONFIG))).toBe('No calls to execute');
  });

  test('caps the migration by V2 available liquidity', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    setupBaseEvmMocks(evmMock, {usdcBalance: 0n});
    mockV2(evmMock, 1000_000000n, 50_000000n);
    expect(onCronTrigger(makeRuntime({...V2_CONFIG, migrationMinUsd: '1000000000'}))).toBe(
      'No calls to execute',
    );
  });
});
