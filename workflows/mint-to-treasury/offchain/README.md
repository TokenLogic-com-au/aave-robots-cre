# Mint To Treasury — CRE workflows

Off-chain CRE workflows driving [`MintToTreasuryReceiver`](../src/MintToTreasuryReceiver.sol).
Daily at 06:00 UTC, each network's handler sends all of the network's v3 pools (from
`V3_POOLS_BY_CHAIN` in the shared `addresses.ts`, read from the address book) in one
`checkUpkeep`; when any can be minted it signs the returned `performData` and writes it
back as the receiver's `onReport`, then logs each `MintedToTreasury` event of the tx.

CRE allows 10 triggers per workflow, so the networks are split across three workflows,
`mint-to-treasury-1/2/3`, one config each.

## Files

| File                             | Purpose                                                             |
| -------------------------------- | ------------------------------------------------------------------- |
| `main.ts`                        | Entry point — builds the runner from the config in `workflow.yaml`. |
| `workflow.ts`                    | `initWorkflow` (one handler per network) + `createReceiverHandler`. |
| `config.production-{1,2,3}.json` | Receiver per network, one config per workflow.                      |
| `workflow.test.ts`               | `bun test` unit suite (mocked cre-sdk EVM client).                  |

Each `receiver` is filled in after the `MintToTreasuryReceiver` is deployed on that
network; a network with no receiver, or no pool in the address book, registers no trigger.

## Gas

The workflow writes through the shared `submitReport`, which uses `eth_estimateGas` only to
skip a write that would revert or not fit the network's CRE quota with the forwarder
overhead, and sends no `gasConfig`, so the DON applies its default limit. Minting the four
Ethereum pools in one report costs ~4.2M gas on a mainnet fork.

## Simulate / deploy

```bash
# from workflows/ (the directory with project.yaml)
cre workflow simulate ./mint-to-treasury/offchain --target=mint-to-treasury-1-production-settings --non-interactive --trigger-index=0

# --unsigned prints the tx for the owner Safe to propose (does not broadcast)
cre workflow deploy   ./mint-to-treasury/offchain --target=mint-to-treasury-1-production-settings --unsigned
cre workflow activate ./mint-to-treasury/offchain --target=mint-to-treasury-1-production-settings --unsigned --yes
```

Or via the `package.json` scripts (`npm run simulate:1`, `npm run deploy:1:unsigned`, ...),
one set per workflow.

## Test

```bash
make test-offchain-mint-to-treasury && make typecheck-mint-to-treasury
```
