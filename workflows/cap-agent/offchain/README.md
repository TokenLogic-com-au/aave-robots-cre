# CapAgent — CRE workflow

Off-chain CRE workflow driving [`CapAgentReceiver`](../src/CapAgentReceiver.sol). Every 5
minutes, for each chain with a `receiver`, it calls the receiver's `checkUpkeep` (empty
`checkData`) and, when updates are ready, signs the returned `performData` and writes it
back as the receiver's `onReport`. Faster polling adds nothing: the hub rate limits each
agent and market with its minimum delay.

Each write is estimated once and sent without a `gasConfig`, so the DON attaches its
default gas limit, the CRE write quota (`MAX_WRITE_GAS`, 16,777,216). It is skipped and
logged when `estimate * 64/63 + WRITE_OVERHEAD_GAS` (250k, forwarder verification and call)
exceeds the quota, and reported as failed when `onReport` reverts inside the forwarder tx.

## Config

`receiver` is filled in after the contract is deployed on each chain. Chains with an empty
`receiver` get no trigger. One cron trigger per chain (6, within CRE's 10 per workflow).

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
[`workflow.yaml`](workflow.yaml) (`cap-agent-production`).

## Testing

```bash
npm run typecheck   # tsc --noEmit (needs shared/offchain deps installed)
bun test            # workflow.test.ts
```
