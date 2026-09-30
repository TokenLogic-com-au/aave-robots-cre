# RefreshRewards — CRE workflow

Off-chain CRE workflow driving [`RefreshRewardsReceiver`](../src/RefreshRewardsReceiver.sol).
On each cron tick, for every configured stataToken factory it calls the receiver's
`checkUpkeep`; when a refresh is needed it signs the returned `performData` and
writes it back as the receiver's `onReport`.

## Config

`receiver` is filled in after the contract is deployed on each chain; `factories`
come from `aave-address-book` (`STATA_FACTORY`) and must also be enabled on the
receiver. Chains with an empty `receiver` get no trigger, so the workflow can only
be simulated once at least one receiver is set.

## Setup

```bash
cd workflows/refresh-rewards/offchain && npm install   # or `make install` from repo root
```

## Simulate / deploy

```bash
# from workflows/ (the directory with project.yaml)
cre workflow simulate ./refresh-rewards/offchain --env=../.env --target=refresh-rewards-production-settings --non-interactive --trigger-index=0

# --unsigned prints the tx for the owner Safe to propose (does not broadcast)
cre workflow deploy   ./refresh-rewards/offchain --env=../.env --target=refresh-rewards-production-settings --unsigned
cre workflow activate ./refresh-rewards/offchain --env=../.env --target=refresh-rewards-production-settings --unsigned --yes
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
