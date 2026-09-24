import {describe, expect} from 'bun:test';
import {TxStatus, getNetwork} from '@chainlink/cre-sdk';
import {EvmMock, newTestRuntime, test} from '@chainlink/cre-sdk/test';
import {
  bytesToHex,
  decodeAbiParameters,
  decodeFunctionData,
  hexToBytes,
  parseAbiParameters,
  type Address,
  type Hex,
} from 'viem';

import {IAaveCREReceiverABI} from '../../shared/offchain/abi/IAaveCREReceiver';
import {MAX_WRITE_GAS} from '../../shared/offchain/checkUpkeep';
import {
  CHECK_UPKEEP_SELECTOR,
  encodeCheckUpkeepResult,
  type CallContractInput,
} from '../../shared/offchain/testing/mocks';
import {configSchema} from './types';
import {createReceiverHandler, initWorkflow} from './workflow';

const CHAIN_NAME = 'ethereum-mainnet';
const CHAIN_SELECTOR = getNetwork({
  chainFamily: 'evm',
  chainSelectorName: CHAIN_NAME,
  isTestnet: false,
})!.chainSelector.selector;

const RECEIVER = '0x1111111111111111111111111111111111111111' as Address;
const GSM_A = '0x2222222222222222222222222222222222222222' as Address;
const GSM_B = '0x3333333333333333333333333333333333333333' as Address;
const TX_HASH = ('0xab' + 'cd'.repeat(31)) as Hex;
const MIN_FEES = 1000n * 10n ** 18n;
// The workflow treats performData as opaque (it only signs it), so any non-empty payload works.
const PERFORM_DATA = '0xdeadbeef' as Hex;

const NETWORK = {
  chainName: CHAIN_NAME,
  isTestnet: false,
  receiver: RECEIVER,
  gsms: [GSM_A, GSM_B] as [Address, ...Address[]],
  minFees: MIN_FEES,
};
const RAW_NETWORK = {...NETWORK, minFees: MIN_FEES.toString()};

// Mocks callContract for a single checkUpkeep call, returning the given result and
// handing the received checkData to `onCheckData` when provided.
function checkUpkeepMock(
  upkeepNeeded: boolean,
  performData: Hex = PERFORM_DATA,
  onCheckData?: (checkData: Hex) => void,
) {
  return (req: CallContractInput): {data: Uint8Array} => {
    const data = bytesToHex(req.call.data);
    const selector = data.slice(0, 10).toLowerCase();
    if (selector === CHECK_UPKEEP_SELECTOR) {
      const [checkData] = decodeFunctionData({abi: IAaveCREReceiverABI, data}).args as [Hex];
      onCheckData?.(checkData);
      return {data: encodeCheckUpkeepResult(upkeepNeeded, performData)};
    }
    throw new Error(`checkUpkeepMock: unmocked selector ${selector}`);
  };
}

const handle = createReceiverHandler(NETWORK);

describe('gsm-fee-claimer workflow', () => {
  test('passes the configured gsms and threshold as checkData', () => {
    let received: Hex | undefined;
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(false, '0x', (checkData) => {
      received = checkData;
    });

    handle(newTestRuntime() as never);
    const [gsms, minFees] = decodeAbiParameters(
      parseAbiParameters('address[], uint256'),
      received!,
    );
    expect(gsms).toEqual([GSM_A, GSM_B]);
    expect(minFees).toBe(MIN_FEES);
  });

  test('returns "No fees to distribute" when checkUpkeep is false', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(false, '0x');

    expect(handle(newTestRuntime() as never)).toBe('No fees to distribute');
  });

  test('returns "No fees to distribute" when checkUpkeep returns empty data', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = () => ({data: new Uint8Array(0)});

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('No fees to distribute');
    expect(runtime.getLogs().find((l) => l.includes('returned empty data'))).toBeDefined();
  });

  test('returns "No fees to distribute" and logs when checkUpkeep reverts', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = () => {
      throw new Error('checkUpkeep reverted');
    };

    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('No fees to distribute');
    expect(
      runtime.getLogs().find((l) => l.includes('checkUpkeep reverted — skipping')),
    ).toBeDefined();
  });

  test('returns "submit skipped" when estimateGas reverts', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true);
    evmMock.estimateGas = () => {
      throw new Error('reverted');
    };

    expect(handle(newTestRuntime() as never)).toBe('submit skipped');
  });

  test('returns "submit skipped" when the estimate exceeds the write quota', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true);
    evmMock.estimateGas = () => ({gas: MAX_WRITE_GAS + 1n});
    const runtime = newTestRuntime();
    expect(handle(runtime as never)).toBe('submit skipped');
    expect(runtime.getLogs().find((l) => l.includes('exceeds max write gas'))).toBeDefined();
  });

  test('submits the signed performData with the full write quota', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true);
    evmMock.estimateGas = () => ({gas: 100_000n});
    let gasLimit: bigint | undefined;
    evmMock.writeReport = (input) => {
      gasLimit = input.gasConfig?.gasLimit;
      return {txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)};
    };

    expect(handle(newTestRuntime() as never)).toBe(`fees distributed, tx=${TX_HASH}`);
    expect(gasLimit).toBe(MAX_WRITE_GAS);
  });

  test('returns "submit skipped" and logs when writeReport is not SUCCESS', () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = checkUpkeepMock(true);
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

describe('config', () => {
  test('normalizes wrong-case addresses and parses minFees', () => {
    const config = configSchema.parse({
      schedule: '* * * * *',
      evms: [
        {
          ...RAW_NETWORK,
          receiver: '0x249396a890F89D47F89326d7EE116b1d374fb3A9',
          gsms: ['0x3a3868898305f04bec7fea77becff04c13444112'],
        },
      ],
    });
    expect(config.evms[0].receiver).toBe('0x249396a890F89D47F89326d7EE116b1d374Fb3A9');
    expect(config.evms[0].gsms[0]).toBe('0x3A3868898305f04beC7FEa77BecFf04C13444112');
    expect(config.evms[0].minFees).toBe(MIN_FEES);
  });

  test('rejects malformed addresses, an empty gsm list and a non-numeric minFees', () => {
    const evms = (patch: object) => ({schedule: '* * * * *', evms: [{...RAW_NETWORK, ...patch}]});
    expect(() => configSchema.parse(evms({gsms: ['0x1234']}))).toThrow();
    expect(() => configSchema.parse(evms({receiver: 'not-an-address'}))).toThrow();
    expect(() => configSchema.parse(evms({gsms: []}))).toThrow();
    expect(() => configSchema.parse(evms({minFees: '1e21'}))).toThrow();
  });

  test('accepts the production config', async () => {
    const raw = await Bun.file(`${import.meta.dir}/config.production.json`).json();
    const config = configSchema.parse(raw);
    expect(config.evms.map((e) => e.chainName)).toEqual([
      'ethereum-mainnet',
      'ethereum-mainnet-arbitrum-1',
      'plasma-mainnet',
      'monad-mainnet',
    ]);
    for (const net of config.evms) {
      expect(
        getNetwork({chainFamily: 'evm', chainSelectorName: net.chainName, isTestnet: false}),
      ).toBeDefined();
    }
  });
});

describe('initWorkflow', () => {
  test('creates one handler per network with a receiver', () => {
    const handlers = initWorkflow({schedule: '* * * * *', evms: [NETWORK]});
    expect(handlers.length).toBe(1);
  });

  test('skips networks with empty receiver', () => {
    const handlers = initWorkflow({schedule: '* * * * *', evms: [{...NETWORK, receiver: ''}]});
    expect(handlers.length).toBe(0);
  });
});
