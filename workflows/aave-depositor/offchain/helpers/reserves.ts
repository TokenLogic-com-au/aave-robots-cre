import type {Runtime} from '@chainlink/cre-sdk';
import type {Address} from 'viem';
import type {EvmClient, Result} from '../types';
import type {ChainConfig} from './config';
import {decodeOrNull, multicall} from './multicall';
import {calls, decode, getAllReservesTokens, getAssetsPrices, type ReserveConfig} from './reads';

export type Reserve = {
  token: Address;
  key: string;
  price: bigint;
  config: ReserveConfig | null;
  balance: bigint;
  v2AToken: Address | null;
  v2Balance: bigint;
  v2Liquidity: bigint | null;
};

export type ActiveReserve = Reserve & {config: ReserveConfig};

export function isActive(reserve: Reserve): reserve is ActiveReserve {
  return reserve.config !== null && reserve.config.isActive && !reserve.config.isFrozen;
}

// Snapshots every V3 reserve in 4 chain reads (6 with a V2 pool): tokens, prices, configs,
// Collector balances, V2 aToken addresses, then V2 aToken balances + liquidity.
export function fetchReserves(
  runtime: Runtime<unknown>,
  evmClient: EvmClient,
  chain: ChainConfig,
): Result<Reserve[]> {
  const tokensRes = getAllReservesTokens(runtime, evmClient, chain.dataProviderV3);
  if (!tokensRes.ok) return {ok: false, error: `reserves: ${tokensRes.error}`};
  const tokens = tokensRes.value;
  if (tokens.length === 0) return {ok: true, value: []};

  const pricesRes = getAssetsPrices(runtime, evmClient, chain.priceOracle, tokens);
  if (!pricesRes.ok) return {ok: false, error: `prices: ${pricesRes.error}`};

  const configsRes = multicall(
    runtime,
    evmClient,
    tokens.map((t) => calls.reserveConfig(chain.dataProviderV3, t)),
  );
  if (!configsRes.ok) return {ok: false, error: `reserve configs: ${configsRes.error}`};

  const balancesRes = multicall(
    runtime,
    evmClient,
    tokens.map((t) => calls.balanceOf(t, chain.collector)),
  );
  if (!balancesRes.ok) return {ok: false, error: `balances: ${balancesRes.error}`};

  const reserves: Reserve[] = tokens.map((token, i) => ({
    token,
    key: token.toLowerCase(),
    price: pricesRes.value[i],
    config: decodeOrNull(configsRes.value[i], decode.reserveConfig),
    balance: decodeOrNull(balancesRes.value[i], decode.uint) ?? 0n,
    v2AToken: null,
    v2Balance: 0n,
    v2Liquidity: null,
  }));
  if (!chain.v2) return {ok: true, value: reserves};

  const {dataProvider} = chain.v2;
  const v2ATokensRes = multicall(
    runtime,
    evmClient,
    tokens.map((t) => calls.v2ReserveAToken(dataProvider, t)),
  );
  if (!v2ATokensRes.ok) return {ok: false, error: `V2 aTokens: ${v2ATokensRes.error}`};
  for (const [i, r] of reserves.entries()) {
    r.v2AToken = decodeOrNull(v2ATokensRes.value[i], decode.aToken);
  }
  const inV2 = reserves.filter((r): r is Reserve & {v2AToken: Address} => r.v2AToken !== null);

  const v2StateRes = multicall(runtime, evmClient, [
    ...inV2.map((r) => calls.balanceOf(r.v2AToken, chain.collector)),
    ...inV2.map((r) => calls.v2ReserveLiquidity(dataProvider, r.token)),
  ]);
  if (!v2StateRes.ok) return {ok: false, error: `V2 balances: ${v2StateRes.error}`};
  for (const [i, r] of inV2.entries()) {
    r.v2Balance = decodeOrNull(v2StateRes.value[i], decode.uint) ?? 0n;
    r.v2Liquidity = decodeOrNull(v2StateRes.value[inV2.length + i], decode.v2ReserveLiquidity);
  }
  return {ok: true, value: reserves};
}
