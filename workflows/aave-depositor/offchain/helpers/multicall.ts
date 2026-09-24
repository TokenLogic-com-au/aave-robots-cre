import {
  encodeCallMsg,
  bytesToHex,
  LAST_FINALIZED_BLOCK_NUMBER,
  type Runtime,
} from '@chainlink/cre-sdk';
import {encodeFunctionData, decodeFunctionResult, zeroAddress, type Hex} from 'viem';
import type {EvmClient, Result} from '../types';
import {IMulticall3, MULTICALL3_ADDRESS} from '../abi/IMulticall3';

export type Call = {target: Hex; callData: Hex};
export type Block = 'finalized' | 'latest';

export function readContract(
  runtime: Runtime<unknown>,
  evmClient: EvmClient,
  to: Hex,
  data: Hex,
  block: Block = 'finalized',
): Result<Hex> {
  try {
    const response = evmClient
      .callContract(runtime, {
        call: encodeCallMsg({from: zeroAddress, to, data}),
        ...(block === 'finalized' ? {blockNumber: LAST_FINALIZED_BLOCK_NUMBER} : {}),
      })
      .result();
    return {ok: true, value: bytesToHex(response.data)};
  } catch (e) {
    return {ok: false, error: String(e)};
  }
}

export function readAndDecode<T>(
  runtime: Runtime<unknown>,
  evmClient: EvmClient,
  to: Hex,
  data: Hex,
  decode: (data: Hex) => T,
  block: Block = 'finalized',
): Result<T> {
  const res = readContract(runtime, evmClient, to, data, block);
  if (!res.ok) return res;
  try {
    return {ok: true, value: decode(res.value)};
  } catch (e) {
    return {ok: false, error: String(e)};
  }
}

// One Multicall3.aggregate3 read; a failed sub-call yields null. CRE caps chain reads per
// execution (15 at the time of writing), so callers pack independent reads into one call.
export function multicall(
  runtime: Runtime<unknown>,
  evmClient: EvmClient,
  calls: Call[],
  block: Block = 'finalized',
): Result<(Hex | null)[]> {
  if (calls.length === 0) return {ok: true, value: []};
  const callData = encodeFunctionData({
    abi: IMulticall3,
    functionName: 'aggregate3',
    args: [calls.map((c) => ({target: c.target, allowFailure: true, callData: c.callData}))],
  });
  return readAndDecode(
    runtime,
    evmClient,
    MULTICALL3_ADDRESS,
    callData,
    (data) =>
      decodeFunctionResult({abi: IMulticall3, functionName: 'aggregate3', data}).map((r) =>
        r.success && r.returnData !== '0x' ? r.returnData : null,
      ),
    block,
  );
}

export function decodeOrNull<T>(data: Hex | null, decode: (data: Hex) => T): T | null {
  if (data === null) return null;
  try {
    return decode(data);
  } catch {
    return null;
  }
}
