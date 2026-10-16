# Governance Chain Robot — CRE workflow

Off-chain CRE workflow driving
[`GovernanceChainRobotReceiver`](../src/GovernanceChainRobotReceiver.sol). On the cron in
`schedule` (every 30 seconds, as the `MailboxCRE` workflow runs BGD's keeper today) it
calls the receiver's `checkUpkeep` (with empty `checkData`) and, when an action is due:

1. estimates `onReport(0x, performData)` on the receiver and skips the tick if it reverts
   (every action stale) or exceeds the CRE write quota (`MAX_WRITE_GAS`, 16,777,216 gas);
2. signs `performData` and writes it as the receiver's `onReport`, requesting the full
   quota as the gas limit. Not the estimate: `onReport` catches reverting Governance
   calls, so the estimate of a batch can leave one action out of gas while another
   succeeds.

The quota check lives here rather than in `shared/offchain/checkUpkeep.ts`. A full batch
(5 actions) stays far below it: activating voting costs ~0.8M gas and executing a
single-payload proposal ~0.8M on the fork tests.

## Config

`receiver` is filled in after the `GovernanceChainRobotReceiver` is deployed on Ethereum.
With an empty `receiver` the workflow has no trigger, so it can only be simulated once it's
set.

## Setup

```bash
cd workflows/governance-chain-robot/offchain && npm install   # or `make install` from repo root
```

## Simulate / deploy

```bash
# from workflows/ (the directory with project.yaml)
cre workflow simulate ./governance-chain-robot/offchain --env=../.env --target=governance-chain-robot-production-settings --non-interactive --trigger-index=0

# --unsigned prints the tx for the owner Safe to propose (does not broadcast)
cre workflow deploy   ./governance-chain-robot/offchain --env=../.env --target=governance-chain-robot-production-settings --unsigned
cre workflow activate ./governance-chain-robot/offchain --env=../.env --target=governance-chain-robot-production-settings --unsigned --yes
```

Or via the `package.json` scripts (`npm run simulate:production`,
`npm run deploy:production:unsigned`, …). The workflow name is set in
[`workflow.yaml`](workflow.yaml) (`governance-chain-robot-production`). Deploying again
with the same name updates the existing workflow.

## Testing

```bash
npm run typecheck   # tsc --noEmit (needs shared/offchain deps installed)
bun test            # workflow.test.ts
```
