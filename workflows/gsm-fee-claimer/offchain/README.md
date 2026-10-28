# GSM Fee Claimer — CRE workflow

Off-chain CRE workflow driving [`GsmFeeClaimerReceiver`](../src/GsmFeeClaimerReceiver.sol).
On each cron tick it calls the receiver's `checkUpkeep` with the configured GSMs
abi-encoded as `checkData`; when any of them has accrued fees it signs the returned
`performData` (the subset with fees) and writes it back as the receiver's `onReport`,
which sends those fees to the GHO treasury. One trigger per network.

## Files

| File                     | Purpose                                                              |
| ------------------------ | -------------------------------------------------------------------- |
| `main.ts`                | Entry point — builds the runner from the config in `workflow.yaml`.  |
| `workflow.ts`            | `initWorkflow` (one handler per network) + `createReceiverHandler`.  |
| `types.ts`               | Shared config schema with per-network `gsms` and `minFees`.          |
| `config.production.json` | Receiver + GSM list per network (Ethereum, Arbitrum, Plasma, Monad). |
| `workflow.test.ts`       | `bun test` unit suite (mocked cre-sdk EVM client).                   |

Each `receiver` is filled in after the corresponding `GsmFeeClaimerReceiver` is
deployed on that network. Addresses are normalized on parse, so casing in the JSON
does not matter (and is not checksum-verified).

`minFees` is in GHO wei (18 decimals on every network); a GSM below it is left to
accrue until the next run.

## Gas

The workflow writes through the shared `submitReport`, which uses `eth_estimateGas` only
to skip a write that would revert or not fit the CRE quota with the forwarder overhead,
and sends no `gasConfig` with the write, so in production the DON applies its default
limit, the CRE quota (the simulator estimates instead).

## Setup

```bash
cd workflows/gsm-fee-claimer/offchain && npm install   # or `make install` from repo root
```

## Simulate / deploy

```bash
# from workflows/ (the directory with project.yaml)
cre workflow simulate ./gsm-fee-claimer/offchain --target=gsm-fee-claimer-production-settings --non-interactive --trigger-index=0

# --unsigned prints the tx for the owner Safe to propose (does not broadcast)
cre workflow deploy   ./gsm-fee-claimer/offchain --target=gsm-fee-claimer-production-settings --unsigned
cre workflow activate ./gsm-fee-claimer/offchain --target=gsm-fee-claimer-production-settings --unsigned --yes
```

Or via the `package.json` scripts (`npm run simulate:production`,
`npm run deploy:production:unsigned`, ...).

## Test

```bash
make test-offchain-gsm-fee-claimer && make typecheck-gsm-fee-claimer
```
