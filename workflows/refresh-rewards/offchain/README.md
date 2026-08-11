# RefreshRewards — CRE workflow

Off-chain CRE workflow driving [`RefreshRewardsReceiver`](../src/RefreshRewardsReceiver.sol).
On each cron tick, for every configured `(factory, controller)` pool it calls the
receiver's `checkUpkeep`; when a refresh is needed it signs the returned
`performData` and writes it back as the receiver's `onReport`. The receiver does
the stataToken enumeration itself, so the workflow performs no off-chain reads —
it only forwards the pool addresses.

## Files

| File                     | Purpose                                                              |
| ------------------------ | -------------------------------------------------------------------- |
| `main.ts`                | Entry point — builds the runner from `config.production.json`.       |
| `workflow.ts`            | `initWorkflow` (one handler per pool) + `createPoolHandler`.         |
| `types.ts`               | Zod config schema (`schedule`, `evms[].receiver`, `evms[].pools[]`). |
| `config.production.json` | Per-chain receiver + `(factory, controller)` pools.                  |
| `workflow.test.ts`       | `bun test` unit suite (mocked cre-sdk EVM client).                   |

`receiver` is filled in after the contract is deployed on each chain; `factory` /
`controller` come from `aave-address-book` (`STATA_FACTORY` /
`DEFAULT_INCENTIVES_CONTROLLER`).

## Setup

```bash
cd workflows/refresh-rewards/offchain && npm install   # or `make install` from repo root
```

## Simulate / deploy

```bash
# from workflows/ (the directory with project.yaml)
cre workflow simulate ./refresh-rewards/offchain --target=refresh-rewards-production-settings --non-interactive --trigger-index=0

# --unsigned prints the tx for the owner Safe to propose (does not broadcast)
cre workflow deploy   ./refresh-rewards/offchain --target=refresh-rewards-production-settings --unsigned
cre workflow activate ./refresh-rewards/offchain --target=refresh-rewards-production-settings --unsigned --yes
```

Or via the `package.json` scripts (`npm run simulate:production`,
`npm run deploy:production:unsigned`, …). The workflow name is set in
[`workflow.yaml`](workflow.yaml) (`refresh-rewards-production`). Deploying again
with the same name updates the existing workflow.

## Testing

```bash
npm run typecheck   # tsc --noEmit (needs shared/offchain deps installed)
bun test            # workflow.test.ts
```
