# Slashing — CRE workflow

Off-chain CRE workflow driving [`SlashingReceiver`](../src/SlashingReceiver.sol).
It calls the receiver's `checkUpkeep` (with empty `checkData`) and, when a reserve needs
slashing, signs the returned `performData` and writes it back as the receiver's
`onReport`. Two triggers run it:

- a log trigger on the Pool's `DeficitCreated` event (`LATEST` confidence), so a deficit
  left by a liquidation is slashed within a few blocks, close to BGD's per-block robot;
- the cron in `schedule` (hourly) as a fallback, for deficits that don't come from a
  liquidation (e.g. a lowered Umbrella deficit offset) or a missed log.

For a log, `checkUpkeep` is read at the log's block; for the cron, at the latest block.
Several `DeficitCreated` logs in one block start one execution each, so all but the
first report may revert with `NoSlashesPerformed` onchain.

## Config

`receiver` is filled in after the `SlashingReceiver` is deployed on Ethereum. With an
empty `receiver` the workflow has no trigger, so it can only be simulated once it's set.

## Setup

```bash
cd workflows/slashing/offchain && npm install   # or `make install` from repo root
```

## Simulate / deploy

```bash
# from workflows/ (the directory with project.yaml)
cre workflow simulate ./slashing/offchain --env=../.env --target=slashing-production-settings --non-interactive --trigger-index=0

# the DeficitCreated log trigger, replaying a real event (tx 0xfd76…c427 on mainnet)
cre workflow simulate ./slashing/offchain --env=../.env --target=slashing-production-settings --non-interactive --trigger-index=1 \
  --evm-tx-hash 0xfd76e2f691f2b18e4116d41d7842c7717b77674d3092827d58daad3dc6a9c427 --evm-event-index 4

# --unsigned prints the tx for the owner Safe to propose (does not broadcast)
cre workflow deploy   ./slashing/offchain --env=../.env --target=slashing-production-settings --unsigned
cre workflow activate ./slashing/offchain --env=../.env --target=slashing-production-settings --unsigned --yes
```

Or via the `package.json` scripts (`npm run simulate:production`,
`npm run deploy:production:unsigned`, …). The workflow name is set in
[`workflow.yaml`](workflow.yaml) (`slashing-production`). Deploying again with the
same name updates the existing workflow.

## Testing

```bash
npm run typecheck   # tsc --noEmit (needs shared/offchain deps installed)
bun test            # workflow.test.ts
```
