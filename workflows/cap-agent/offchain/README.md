# CapAgent — CRE workflow

Off-chain CRE workflow driving [`CapAgentReceiver`](../src/CapAgentReceiver.sol) on every
covered chain. On each cron tick (every 5 minutes), for each chain with a `receiver`, it
calls the receiver's `checkUpkeep` (with empty `checkData`) and, when updates are ready to
inject, estimates `onReport` with the returned `performData`, signs it and writes it back
as the receiver's `onReport`.

A write whose `onReport` estimate exceeds the CRE write gas quota (`MAX_WRITE_GAS`,
16,777,216, the gas the DON attaches to a write) is skipped and logged, since it would run
out of gas inside the forwarder. The receiver caps a report at 10 market updates, so this
should not happen in practice. The estimate and write live in the robot's
[`workflow.ts`](workflow.ts) rather than the shared `submitReport`, which doesn't expose
the estimate.

## Config

`receiver` is filled in after the contract is deployed on each chain. Chains with an
empty `receiver` get no trigger, so the workflow can only be simulated once at least one
receiver is set. One cron trigger per chain (6, within CRE's 10 per workflow).

## Setup

```bash
cd workflows/cap-agent/offchain && npm install   # or `make install` from repo root
```

## Simulate / deploy

```bash
# from workflows/ (the directory with project.yaml)
cre workflow simulate ./cap-agent/offchain --env=../.env --target=cap-agent-production-settings --non-interactive --trigger-index=0

# --unsigned prints the tx for the owner Safe to propose (does not broadcast)
cre workflow deploy   ./cap-agent/offchain --env=../.env --target=cap-agent-production-settings --unsigned
cre workflow activate ./cap-agent/offchain --env=../.env --target=cap-agent-production-settings --unsigned --yes
```

Or via the `package.json` scripts (`npm run simulate:production`,
`npm run deploy:production:unsigned`, …). The workflow name is set in
[`workflow.yaml`](workflow.yaml) (`cap-agent-production`). Deploying again with the same
name updates the existing workflow.

## Testing

```bash
npm run typecheck   # tsc --noEmit (needs shared/offchain deps installed)
bun test            # workflow.test.ts
```
