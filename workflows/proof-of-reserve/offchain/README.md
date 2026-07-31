# ProofOfReserve — CRE workflow

Off-chain CRE workflow driving [`ProofOfReserveReceiver`](../src/ProofOfReserveReceiver.sol).
On each cron tick, for every configured executor it calls the receiver's
`checkUpkeep`; when an emergency action is needed it signs the returned
`performData` and writes it back as the receiver's `onReport`. The executor address
rides in `checkData`, so the workflow performs no off-chain reads.

## Files

| File                     | Purpose                                                                  |
| ------------------------ | ------------------------------------------------------------------------ |
| `main.ts`                | Entry point — builds the runner from `config.production.json`.           |
| `workflow.ts`            | `initWorkflow` (one handler per executor) + `createExecutorHandler`.     |
| `types.ts`               | Zod config schema (`schedule`, `evms[].receiver`, `evms[].executors[]`). |
| `config.production.json` | Per-chain receiver + executors (Avalanche only).                         |
| `workflow.test.ts`       | `bun test` unit suite (mocked cre-sdk EVM client).                       |

`receiver` is filled in after the `ProofOfReserveReceiver` is deployed on Avalanche;
`executors` come from `aave-address-book` (`AaveV2Avalanche.PROOF_OF_RESERVE` /
`AaveV3Avalanche.PROOF_OF_RESERVE`).

## Setup

```bash
cd workflows/proof-of-reserve/offchain && npm install   # or `make install` from repo root
```

## Simulate / deploy

```bash
# from workflows/ (the directory with project.yaml)
cre workflow simulate ./proof-of-reserve/offchain --target=proof-of-reserve-production-settings --non-interactive --trigger-index=0

# --unsigned prints the tx for the owner Safe to propose (does not broadcast)
cre workflow deploy   ./proof-of-reserve/offchain --target=proof-of-reserve-production-settings --unsigned
cre workflow activate ./proof-of-reserve/offchain --target=proof-of-reserve-production-settings --unsigned --yes
```

Or via the `package.json` scripts (`npm run simulate:production`,
`npm run deploy:production:unsigned`, …). The workflow name is set in
[`workflow.yaml`](workflow.yaml) (`proof-of-reserve-production`). Deploying again
with the same name updates the existing workflow.

## Testing

```bash
npm run typecheck   # tsc --noEmit (needs shared/offchain deps installed)
bun test            # workflow.test.ts
```
