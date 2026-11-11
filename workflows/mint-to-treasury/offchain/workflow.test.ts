import {describe, expect} from 'bun:test';
import {TxStatus} from '@chainlink/cre-sdk';
import {EvmMock, newTestRuntime, test} from '@chainlink/cre-sdk/test';
import {
  bytesToHex,
  encodeAbiParameters,
  encodeEventTopics,
  hexToBytes,
  parseAbiParameters,
  type Hex,
} from 'viem';

import {IPoolABI} from '../../shared/offchain/abi/IPool';
import {V3_POOLS_BY_CHAIN, v3PoolsFor} from '../../shared/offchain/addresses';
import {maxWriteGasOf} from '../../shared/offchain/network';
import {
  chainSelectorOf,
  checkUpkeepMock,
  mockLog,
  mockReceipt,
} from '../../shared/offchain/testing/mocks';
import {
  configSchema,
  createReceiverHandler,
  decodePools,
  encodePools,
  initWorkflow,
} from './workflow';
import config1 from './config.production-1.json';
import config2 from './config.production-2.json';
import config3 from './config.production-3.json';

const CHAIN_NAME = 'ethereum-mainnet';
const CHAIN_SELECTOR = chainSelectorOf(CHAIN_NAME);
const RECEIVER = '0x1111111111111111111111111111111111111111' as Hex;
const RESERVE_A = '0x2222222222222222222222222222222222222222' as Hex;
const RESERVE_B = '0x3333333333333333333333333333333333333333' as Hex;
const TX_HASH = ('0xab' + 'cd'.repeat(31)) as Hex;
const POOLS = v3PoolsFor(CHAIN_NAME);
const NETWORK = {chainName: CHAIN_NAME, isTestnet: false, receiver: RECEIVER};

function mintedToTreasuryLog(pool: Hex, reserve: Hex, amountMinted: bigint) {
  const topics = encodeEventTopics({
    abi: IPoolABI,
    eventName: 'MintedToTreasury',
    args: {reserve},
  }) as readonly Hex[];
  const data = encodeAbiParameters(parseAbiParameters('uint256'), [amountMinted]);
  return mockLog({address: pool, topics, data});
}

function mockSuccessfulWrite(evmMock: EvmMock, logs: ReturnType<typeof mockLog>[]) {
  evmMock.estimateGas = () => ({gas: 3_000_000n});
  evmMock.writeReport = () => ({txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)});
  evmMock.getTransactionReceipt = () => ({receipt: mockReceipt({txHash: TX_HASH, logs})});
}

const handle = createReceiverHandler(NETWORK);

describe('mint-to-treasury workflow', () => {
  test('sends every pool of the network in one checkUpkeep', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    let checked: readonly Hex[] = [];
    evmMock.callContract = checkUpkeepMock(false, '0x', (checkData) => {
      checked = decodePools(checkData);
    });

    expect(handle(newTestRuntime() as never)).toBe('No pool to mint');
    expect(checked).toEqual(POOLS);
  });

  test('does not write when no pool is mintable', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    let wrote = false;
    evmMock.callContract = checkUpkeepMock(false);
    evmMock.writeReport = () => {
      wrote = true;
      return {txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)};
    };

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('No pool to mint');
    expect(wrote).toBe(false);
    expect(runtime.getLogs().find((l) => l.includes('upkeepNeeded=false'))).toBeDefined();
  });

  test('skips when checkUpkeep reverts', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = () => {
      throw new Error('execution reverted');
    };

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('No pool to mint');
    expect(
      runtime.getLogs().find((l) => l.includes('checkUpkeep reverted — skipping')),
    ).toBeDefined();
  });

  test('skips when the onReport estimate reverts', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true, encodePools(POOLS));
    evmMock.estimateGas = () => {
      throw new Error('ConditionsNotMet()');
    };

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('submit skipped');
    expect(runtime.getLogs().find((l) => l.includes('estimateGas failed'))).toBeDefined();
  });

  test('skips a write estimated above the chain write quota', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    let wrote = false;
    evmMock.callContract = checkUpkeepMock(true, encodePools(POOLS));
    evmMock.estimateGas = () => ({gas: maxWriteGasOf(CHAIN_NAME) + 1n});
    evmMock.writeReport = () => {
      wrote = true;
      return {txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)};
    };

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('submit skipped');
    expect(wrote).toBe(false);
    expect(runtime.getLogs().find((l) => l.includes('exceeds max write gas'))).toBeDefined();
  });

  test('skips when writeReport reverts', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true, encodePools(POOLS));
    evmMock.estimateGas = () => ({gas: 3_000_000n});
    evmMock.writeReport = () => ({txStatus: TxStatus.REVERTED, errorMessage: 'reverted'});

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('submit skipped');
    expect(runtime.getLogs().find((l) => l.includes('writeReport status='))).toBeDefined();
  });

  test('writes the mintable pools and logs every MintedToTreasury event', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    const [core, prime] = POOLS;
    let report: Hex | undefined;
    evmMock.callContract = checkUpkeepMock(true, encodePools([core, prime]));
    mockSuccessfulWrite(evmMock, [
      mintedToTreasuryLog(core, RESERVE_A, 100n),
      mintedToTreasuryLog(core, RESERVE_B, 200n),
      mintedToTreasuryLog(prime, RESERVE_A, 300n),
      mintedToTreasuryLog(RECEIVER, RESERVE_A, 999n),
    ]);
    const writeReport = evmMock.writeReport;
    evmMock.writeReport = (req: never) => {
      report = bytesToHex((req as {report: {rawReport: Uint8Array}}).report.rawReport);
      return writeReport!(req);
    };

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe(`minted 3 reserves on 2 pools, tx=${TX_HASH}`);
    expect(report?.endsWith(encodePools([core, prime]).slice(2))).toBe(true);

    const logs = runtime.getLogs();
    expect(logs.find((l) => l.includes('mintable=2/4'))).toBeDefined();
    expect(
      logs.find((l) => l.includes(core) && l.includes(RESERVE_A) && l.includes('amountMinted=100')),
    ).toBeDefined();
    expect(
      logs.find((l) => l.includes(core) && l.includes(RESERVE_B) && l.includes('amountMinted=200')),
    ).toBeDefined();
    expect(
      logs.find(
        (l) => l.includes(prime) && l.includes(RESERVE_A) && l.includes('amountMinted=300'),
      ),
    ).toBeDefined();
    expect(logs.find((l) => l.includes('amountMinted=999'))).toBeUndefined();
  });

  test('logs a missing MintedToTreasury event', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true, encodePools(POOLS));
    mockSuccessfulWrite(evmMock, []);

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe(`minted 0 reserves on 4 pools, tx=${TX_HASH}`);
    expect(runtime.getLogs().find((l) => l.includes('no MintedToTreasury event found'))).toBe(
      `[${CHAIN_NAME}:${RECEIVER}] no MintedToTreasury event found in tx ${TX_HASH}`,
    );
  });
});

describe('initWorkflow', () => {
  test('creates one handler per configured network', () => {
    const handlers = initWorkflow({
      schedule: '0 6 * * *',
      evms: [
        NETWORK,
        {chainName: 'ethereum-mainnet-arbitrum-1', isTestnet: false, receiver: RECEIVER},
      ],
    });
    expect(handlers.length).toBe(2);
  });

  test('skips networks with no receiver or no known pools', () => {
    const handlers = initWorkflow({
      schedule: '0 6 * * *',
      evms: [
        {chainName: CHAIN_NAME, isTestnet: false, receiver: ''},
        {chainName: 'made-up-chain', isTestnet: false, receiver: RECEIVER},
      ],
    });
    expect(handlers.length).toBe(0);
  });
});

describe('production configs', () => {
  const configs = [config1, config2, config3].map((c) => configSchema.parse(c));

  test('stay within the 10 triggers per workflow', () => {
    for (const config of configs) expect(config.evms.length).toBeLessThanOrEqual(10);
  });

  test('cover every network with pools exactly once', () => {
    const chains = configs.flatMap((c) => c.evms.map((e) => e.chainName));
    expect(new Set(chains).size).toBe(chains.length);
    expect([...chains].sort()).toEqual(Object.keys(V3_POOLS_BY_CHAIN).sort());
  });
});
