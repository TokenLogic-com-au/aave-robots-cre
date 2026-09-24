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
import type {EvmClient, Result} from '../types';
import {IAaveDataProviderV2} from '../abi/IAaveDataProviderV2';
import {IAaveDataProviderV3} from '../abi/IAaveDataProviderV3';
import {IAavePriceOracle} from '../abi/IAavePriceOracle';
import {IERC20} from '../abi/IERC20';
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
    encodeFunctionData({abi: IAaveDataProviderV3, functionName: 'getAllReservesTokens'}),
    (data) =>
      decodeFunctionResult({
        abi: IAaveDataProviderV3,
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
    encodeFunctionData({abi: IAavePriceOracle, functionName: 'getAssetsPrices', args: [assets]}),
    (data) => [
      ...decodeFunctionResult({abi: IAavePriceOracle, functionName: 'getAssetsPrices', data}),
    ],
  );
}

export const calls = {
  reserveConfig: (dataProviderV3: Address, asset: Address): Call => ({
    target: dataProviderV3,
    callData: encodeFunctionData({
      abi: IAaveDataProviderV3,
      functionName: 'getReserveConfigurationData',
      args: [asset],
    }),
  }),
  reserveCaps: (dataProviderV3: Address, asset: Address): Call => ({
    target: dataProviderV3,
    callData: encodeFunctionData({
      abi: IAaveDataProviderV3,
      functionName: 'getReserveCaps',
      args: [asset],
    }),
  }),
  reserveAToken: (dataProviderV3: Address, asset: Address): Call => ({
    target: dataProviderV3,
    callData: encodeFunctionData({
      abi: IAaveDataProviderV3,
      functionName: 'getReserveTokensAddresses',
      args: [asset],
    }),
  }),
  v2ReserveAToken: (dataProviderV2: Address, asset: Address): Call => ({
    target: dataProviderV2,
    callData: encodeFunctionData({
      abi: IAaveDataProviderV2,
      functionName: 'getReserveTokensAddresses',
      args: [asset],
    }),
  }),
  v2ReserveLiquidity: (dataProviderV2: Address, asset: Address): Call => ({
    target: dataProviderV2,
    callData: encodeFunctionData({
      abi: IAaveDataProviderV2,
      functionName: 'getReserveData',
      args: [asset],
    }),
  }),
  balanceOf: (token: Address, account: Address): Call => ({
    target: token,
    callData: encodeFunctionData({abi: IERC20, functionName: 'balanceOf', args: [account]}),
  }),
  totalSupply: (token: Address): Call => ({
    target: token,
    callData: encodeFunctionData({abi: IERC20, functionName: 'totalSupply'}),
  }),
};

export const decode = {
  reserveConfig: (data: Hex): ReserveConfig => {
    const d = decodeFunctionResult({
      abi: IAaveDataProviderV3,
      functionName: 'getReserveConfigurationData',
      data,
    });
    return {decimals: d[0], isActive: d[8], isFrozen: d[9]};
  },
  supplyCap: (data: Hex): bigint =>
    decodeFunctionResult({abi: IAaveDataProviderV3, functionName: 'getReserveCaps', data})[1],
  // V2 and V3 `getReserveTokensAddresses` share the (aToken, stableDebt, variableDebt) shape.
  aToken: (data: Hex): Address | null => {
    const [aToken] = decodeAbiParameters(parseAbiParameters('address, address, address'), data);
    return aToken === zeroAddress ? null : aToken;
  },
  v2ReserveLiquidity: (data: Hex): bigint =>
    decodeFunctionResult({abi: IAaveDataProviderV2, functionName: 'getReserveData', data})[0],
  uint: (data: Hex): bigint => decodeAbiParameters(parseAbiParameters('uint256'), data)[0],
};
