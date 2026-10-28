import type {Runtime} from '@chainlink/cre-sdk';
import {
  decodeAbiParameters,
  decodeFunctionResult,
  encodeFunctionData,
  parseAbiParameters,
  zeroAddress,
  type Address,
  type Hex,
} from 'viem';
import type {EvmClient} from '../../../shared/offchain/checkUpkeep';
import type {Result} from '../types';
import {IAaveProtocolDataProviderV2ABI} from '../../../shared/offchain/abi/IAaveProtocolDataProviderV2';
import {IPoolDataProviderABI} from '../../../shared/offchain/abi/IPoolDataProvider';
import {IAaveOracleABI} from '../../../shared/offchain/abi/IAaveOracle';
import {IERC20ABI} from '../../../shared/offchain/abi/IERC20';
import {readAndDecode, type Call} from './multicall';

export type ReserveConfig = {decimals: bigint; isActive: boolean; isFrozen: boolean};

export function getAllReservesTokens(
  runtime: Runtime<unknown>,
  evmClient: EvmClient,
  dataProviderV3: Address,
): Result<Address[]> {
  return readAndDecode(
    runtime,
    evmClient,
    dataProviderV3,
    encodeFunctionData({abi: IPoolDataProviderABI, functionName: 'getAllReservesTokens'}),
    (data) =>
      decodeFunctionResult({
        abi: IPoolDataProviderABI,
        functionName: 'getAllReservesTokens',
        data,
      }).map((r) => r.tokenAddress),
  );
}

export function getAssetsPrices(
  runtime: Runtime<unknown>,
  evmClient: EvmClient,
  priceOracle: Address,
  assets: Address[],
): Result<bigint[]> {
  return readAndDecode(
    runtime,
    evmClient,
    priceOracle,
    encodeFunctionData({abi: IAaveOracleABI, functionName: 'getAssetsPrices', args: [assets]}),
    (data) => [
      ...decodeFunctionResult({abi: IAaveOracleABI, functionName: 'getAssetsPrices', data}),
    ],
  );
}

export const calls = {
  reserveConfig: (dataProviderV3: Address, asset: Address): Call => ({
    target: dataProviderV3,
    callData: encodeFunctionData({
      abi: IPoolDataProviderABI,
      functionName: 'getReserveConfigurationData',
      args: [asset],
    }),
  }),
  reserveCaps: (dataProviderV3: Address, asset: Address): Call => ({
    target: dataProviderV3,
    callData: encodeFunctionData({
      abi: IPoolDataProviderABI,
      functionName: 'getReserveCaps',
      args: [asset],
    }),
  }),
  reserveAToken: (dataProviderV3: Address, asset: Address): Call => ({
    target: dataProviderV3,
    callData: encodeFunctionData({
      abi: IPoolDataProviderABI,
      functionName: 'getReserveTokensAddresses',
      args: [asset],
    }),
  }),
  v2ReserveAToken: (dataProviderV2: Address, asset: Address): Call => ({
    target: dataProviderV2,
    callData: encodeFunctionData({
      abi: IAaveProtocolDataProviderV2ABI,
      functionName: 'getReserveTokensAddresses',
      args: [asset],
    }),
  }),
  v2ReserveLiquidity: (dataProviderV2: Address, asset: Address): Call => ({
    target: dataProviderV2,
    callData: encodeFunctionData({
      abi: IAaveProtocolDataProviderV2ABI,
      functionName: 'getReserveData',
      args: [asset],
    }),
  }),
  balanceOf: (token: Address, account: Address): Call => ({
    target: token,
    callData: encodeFunctionData({abi: IERC20ABI, functionName: 'balanceOf', args: [account]}),
  }),
  totalSupply: (token: Address): Call => ({
    target: token,
    callData: encodeFunctionData({abi: IERC20ABI, functionName: 'totalSupply'}),
  }),
};

export const decode = {
  reserveConfig: (data: Hex): ReserveConfig => {
    const d = decodeFunctionResult({
      abi: IPoolDataProviderABI,
      functionName: 'getReserveConfigurationData',
      data,
    });
    return {decimals: d[0], isActive: d[8], isFrozen: d[9]};
  },
  supplyCap: (data: Hex): bigint =>
    decodeFunctionResult({abi: IPoolDataProviderABI, functionName: 'getReserveCaps', data})[1],
  // V2 and V3 `getReserveTokensAddresses` share the (aToken, stableDebt, variableDebt) shape.
  aToken: (data: Hex): Address | null => {
    const [aToken] = decodeAbiParameters(parseAbiParameters('address, address, address'), data);
    return aToken === zeroAddress ? null : aToken;
  },
  v2ReserveLiquidity: (data: Hex): bigint =>
    decodeFunctionResult({
      abi: IAaveProtocolDataProviderV2ABI,
      functionName: 'getReserveData',
      data,
    })[0],
  uint: (data: Hex): bigint => decodeAbiParameters(parseAbiParameters('uint256'), data)[0],
};
