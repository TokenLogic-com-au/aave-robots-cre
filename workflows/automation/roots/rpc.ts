import {type ConfidentialHTTPClient, type Runtime} from '@chainlink/cre-sdk';
import type {Hex} from 'viem';
import type {Config} from '../types';

type RpcResult = Record<string, any>;

export function jsonRpcCall(
  confClient: ConfidentialHTTPClient,
  runtime: Runtime<Config>,
  rpcUrl: string,
  method: string,
  params: unknown[],
): RpcResult {
  const requestBody = JSON.stringify({jsonrpc: '2.0', method, params, id: 1});

  const response = confClient
    .sendRequest(runtime, {
      request: {
        url: rpcUrl,
        method: 'POST',
        multiHeaders: {'content-type': {values: ['application/json']}},
        bodyString: requestBody,
      },
    })
    .result();

  if (response.statusCode !== 200) {
    throw new Error(`RPC call ${method} failed with status ${response.statusCode}`);
  }

  const json = JSON.parse(new TextDecoder().decode(response.body));
  if (json.error) {
    throw new Error(`RPC error in ${method}: ${json.error.message}`);
  }
  // eth_getBlockByHash returns {result: null} (no error) for an unknown/reorged hash.
  if (json.result === null || json.result === undefined) {
    throw new Error(`RPC call ${method} returned null result (params: ${JSON.stringify(params)})`);
  }
  return json.result;
}

export function getBlockByHash(
  confClient: ConfidentialHTTPClient,
  runtime: Runtime<Config>,
  rpcUrl: string,
  blockHash: Hex,
): Record<string, string> {
  return jsonRpcCall(confClient, runtime, rpcUrl, 'eth_getBlockByHash', [
    blockHash,
    false,
  ]) as Record<string, string>;
}

export type EthGetProofResult = {
  accountProof: Hex[];
  storageProof: Array<{key: Hex; value: Hex; proof: Hex[]}>;
};

export function getProof(
  confClient: ConfidentialHTTPClient,
  runtime: Runtime<Config>,
  rpcUrl: string,
  address: Hex,
  storageKeys: Hex[],
  blockNumber: Hex,
): EthGetProofResult {
  return jsonRpcCall(confClient, runtime, rpcUrl, 'eth_getProof', [
    address,
    storageKeys,
    blockNumber,
  ]) as EthGetProofResult;
}
