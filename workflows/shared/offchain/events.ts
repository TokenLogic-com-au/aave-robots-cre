import {bytesToHex, type Runtime} from '@chainlink/cre-sdk';
import {
  decodeEventLog,
  type Abi,
  type ContractEventName,
  type DecodeEventLogReturnType,
  type Hex,
} from 'viem';

import type {EvmClient} from './checkUpkeep';

export type EmittedEvent<TAbi extends Abi, TName extends ContractEventName<TAbi>> = {
  emitter: Hex;
  args: DecodeEventLogReturnType<TAbi, TName>['args'];
};

/// The `eventName` events that `emitters` logged in the tx, decoded with `abi`. `emitter` keeps
/// the casing it has in `emitters`.
export function findEvents<TConfig, const TAbi extends Abi, TName extends ContractEventName<TAbi>>(
  runtime: Runtime<TConfig>,
  evmClient: EvmClient,
  txHash: string,
  abi: TAbi,
  eventName: TName,
  emitters: readonly Hex[],
): EmittedEvent<TAbi, TName>[] {
  const {receipt} = evmClient.getTransactionReceipt(runtime, {hash: txHash}).result();
  if (!receipt) return [];

  const byAddress = new Map(emitters.map((e) => [e.toLowerCase(), e]));
  const events: EmittedEvent<TAbi, TName>[] = [];
  for (const log of receipt.logs) {
    const emitter = byAddress.get(bytesToHex(log.address).toLowerCase());
    if (!emitter) continue;
    try {
      const {args} = decodeEventLog({
        abi,
        eventName,
        topics: log.topics.map((t) => bytesToHex(t)) as [Hex, ...Hex[]],
        data: bytesToHex(log.data),
      });
      events.push({emitter, args: args as EmittedEvent<TAbi, TName>['args']});
    } catch {
      // another event of the emitter
    }
  }
  return events;
}
