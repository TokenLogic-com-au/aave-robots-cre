import {addContractMock, EvmMock, newTestRuntime, type TestRuntime} from '@chainlink/cre-sdk/test';
import {TxStatus, type Runtime} from '@chainlink/cre-sdk';
import {bytesToHex, hexToBytes, type Address, type Hex} from 'viem';
import {IAaveDepositorReceiver} from '../abi/IAaveDepositorReceiver';
import {IAaveDataProviderV3} from '../abi/IAaveDataProviderV3';
import {IAavePriceOracle} from '../abi/IAavePriceOracle';
import {IERC20} from '../abi/IERC20';
import {IMulticall3, MULTICALL3_ADDRESS} from '../abi/IMulticall3';
import {configSchema, type Config} from '../types';

// TestRuntime is typed as RuntimeImpl<unknown>; keep Runtime<Config> for the handler
// and getLogs() for assertions in one cast.
export type TypedTestRuntime = Runtime<Config> & Pick<TestRuntime, 'getLogs'>;

export function makeRuntime(raw: unknown): TypedTestRuntime {
  const rt = newTestRuntime();
  rt.config = configSchema.parse(raw);
  return rt as unknown as TypedTestRuntime;
}

export const ADDR = {
  dataProviderV3: '0x1000000000000000000000000000000000000001' as Address,
  dataProviderV2: '0x1000000000000000000000000000000000000002' as Address,
  priceOracle: '0x1000000000000000000000000000000000000003' as Address,
  collector: '0x1000000000000000000000000000000000000004' as Address,
  receiver: '0x1000000000000000000000000000000000000005' as Address,
  forwarder: '0x1000000000000000000000000000000000000006' as Address,
  corePoolV3: '0x1000000000000000000000000000000000000007' as Address,
  corePoolV2: '0x1000000000000000000000000000000000000008' as Address,
  primePoolV3: '0x100000000000000000000000000000000000000b' as Address,
  usdc: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48' as Address,
  usdcATokenV3: '0x1000000000000000000000000000000000000009' as Address,
  usdcATokenV2: '0x100000000000000000000000000000000000000a' as Address,
};

export const TX_HASH = ('0xab' + 'cd'.repeat(31)) as Hex;
export const ZERO_WORKFLOW_ID = `0x${'00'.repeat(32)}` as Hex;
export const GAS_ESTIMATE = 1_000_000n;
export const USDC_PRICE = 1_00000000n;

export const USDC_RESERVE_CONFIG = [
  6n,
  7500n,
  8000n,
  10500n,
  1000n,
  true,
  true,
  false,
  true,
  false,
] as const;

// Mock replies carry bytes or base64 depending on the code path; normalize to hex.
export function replyToHex(data: Uint8Array | string): Hex {
  return data instanceof Uint8Array
    ? bytesToHex(data)
    : bytesToHex(Uint8Array.from(atob(data), (c) => c.charCodeAt(0)));
}

type SubCall = {target: Hex; callData: Hex};

// Multicall3.aggregate3 that fans each sub-call back into the contract mocks registered
// on the same EvmMock, so the workflow's batched reads hit the per-contract handlers.
function mockMulticall3(evmMock: EvmMock) {
  const multicall = addContractMock(evmMock, {address: MULTICALL3_ADDRESS, abi: IMulticall3});
  multicall.aggregate3 = (subCalls: unknown) =>
    (subCalls as readonly SubCall[]).map(({target, callData}) => {
      try {
        const reply = evmMock.callContract!({
          call: {to: hexToBytes(target), data: hexToBytes(callData)},
        } as never) as {data: Uint8Array | string};
        return {success: true, returnData: replyToHex(reply.data)};
      } catch {
        return {success: false, returnData: '0x'};
      }
    });
}

export type MockOptions = {
  usdcBalance?: bigint;
  usdcPrice?: bigint;
  supplyCap?: bigint;
  v3Supply?: bigint;
  // Extra reserves that share USDC's config, price and (uncapped) behaviour.
  extraTokens?: {address: Address; balance: bigint}[];
};

export function setupBaseEvmMocks(evmMock: EvmMock, options: MockOptions = {}) {
  const {
    usdcBalance = 1000_000000n,
    usdcPrice = USDC_PRICE,
    supplyCap = 0n,
    v3Supply = 0n,
    extraTokens = [],
  } = options;
  mockMulticall3(evmMock);

  const dpV3 = addContractMock(evmMock, {address: ADDR.dataProviderV3, abi: IAaveDataProviderV3});
  dpV3.getAllReservesTokens = () => [
    {symbol: 'USDC', tokenAddress: ADDR.usdc},
    ...extraTokens.map((t, i) => ({symbol: `T${i}`, tokenAddress: t.address})),
  ];
  dpV3.getReserveConfigurationData = () => USDC_RESERVE_CONFIG;
  dpV3.getReserveCaps = (asset: unknown) => [0n, asset === ADDR.usdc ? supplyCap : 0n];
  dpV3.getReserveTokensAddresses = () => [
    ADDR.usdcATokenV3,
    '0x0000000000000000000000000000000000000000',
    '0x0000000000000000000000000000000000000000',
  ];

  const oracle = addContractMock(evmMock, {address: ADDR.priceOracle, abi: IAavePriceOracle});
  oracle.getAssetsPrices = (assets: unknown) => (assets as unknown[]).map(() => usdcPrice);

  const usdc = addContractMock(evmMock, {address: ADDR.usdc, abi: IERC20});
  usdc.balanceOf = () => usdcBalance;
  for (const t of extraTokens) {
    addContractMock(evmMock, {address: t.address, abi: IERC20}).balanceOf = () => t.balance;
  }

  const usdcAToken = addContractMock(evmMock, {address: ADDR.usdcATokenV3, abi: IERC20});
  usdcAToken.totalSupply = () => v3Supply;

  // The receiver echoes the encoded calls it is asked to validate.
  const receiver = addContractMock(evmMock, {address: ADDR.receiver, abi: IAaveDepositorReceiver});
  receiver.checkUpkeep = (checkData: unknown) => [true, checkData];
  receiver.FORWARDER = () => ADDR.forwarder;
  receiver.expectedWorkflowId = () => ZERO_WORKFLOW_ID;

  evmMock.estimateGas = () => ({gas: GAS_ESTIMATE});
  evmMock.writeReport = () => ({txStatus: TxStatus.SUCCESS, txHash: hexToBytes(TX_HASH)});

  return {dpV3, oracle, usdc, usdcAToken, receiver};
}
