# GSM Fee Claimer — CRE workflow

Off-chain CRE workflow driving [`GsmFeeClaimerReceiver`](../src/GsmFeeClaimerReceiver.sol).
On each cron tick it calls the receiver's `checkUpkeep` with the configured GSMs
abi-encoded as `checkData`; when any of them has accrued fees it signs the returned
`performData` (the subset with fees) and writes it back as the receiver's `onReport`,
which sends those fees to the GHO treasury. One trigger per network.

## Files

| File                     | Purpose                                                             |
| ------------------------ | ------------------------------------------------------------------- |
| `main.ts`                | Entry point — builds the runner from the config in `workflow.yaml`. |
| `workflow.ts`            | `initWorkflow` (one handler per network) + `createReceiverHandler`. |
| `types.ts`               | Zod config schema (`schedule`, `evms[].receiver`, `evms[].gsms`).   |
| `config.production.json` | Receiver + GSM list per network (Ethereum USDC + USDT, Plasma).     |
| `workflow.test.ts`       | `bun test` unit suite (mocked cre-sdk EVM client).                  |

Each `receiver` is filled in after the corresponding `GsmFeeClaimerReceiver` is
deployed on that network. Addresses are normalized on parse, so casing in the JSON
does not matter (and is not checksum-verified).

After a successful write the workflow reads the transaction receipt and logs one
line per GSM (`FeesDistributed` or `FeeDistributionFailed` with the revert reason),
since a failing GSM does not fail the transaction.

## Gas

Because the receiver catches a failing GSM instead of reverting, `eth_estimateGas`
settles on the gas that lets the first distribution succeed, not all of them. The
workflow therefore uses the estimate only to skip a write that would revert or
exceed the CRE quota, and requests the full quota (`MAX_WRITE_GAS`, 10M) for the
write itself; gas is only paid for what the transaction uses.

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
