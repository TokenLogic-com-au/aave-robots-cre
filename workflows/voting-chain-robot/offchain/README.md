# Voting Chain Robot — CRE workflow

Off-chain CRE workflow driving [`VotingChainRobotReceiver`](../src/VotingChainRobotReceiver.sol)
on the three Governance V3 voting chains, one cron trigger per chain, every 10 minutes like
the other governance robots (`GOVERNANCE_SCHEDULE`). Each run calls the receiver's
`checkUpkeep` (empty `checkData`) and passes the returned `performData` to the shared
`submitReport`, which estimates `onReport`, skips the write if it would revert or not fit
the CRE write quota, and logs a write whose `onReport` reverted inside the forwarder tx. A
full batch of 5 actions stays well below the quota (a `closeAndSendVote` costs ~1.1M).

## Config

Each `receiver` is filled in after the matching `VotingChainRobotReceiver` is deployed.
With an empty `receiver` that chain gets no trigger, so the workflow can only be
simulated once at least one receiver is set.

## Setup

```bash
cd workflows/voting-chain-robot/offchain && npm install   # or `make install` from repo root
```

## Simulate / deploy

```bash
# from workflows/ (the directory with project.yaml)
cre workflow simulate ./voting-chain-robot/offchain --env=../.env --target=voting-chain-robot-production-settings --non-interactive --trigger-index=0

# --unsigned prints the tx for the owner Safe to propose (does not broadcast)
cre workflow deploy   ./voting-chain-robot/offchain --env=../.env --target=voting-chain-robot-production-settings --unsigned
cre workflow activate ./voting-chain-robot/offchain --env=../.env --target=voting-chain-robot-production-settings --unsigned --yes
```

Or via the `package.json` scripts (`npm run simulate:production`,
`npm run deploy:production:unsigned`, …). The workflow name is set in
[`workflow.yaml`](workflow.yaml) (`voting-chain-robot-production`). Deploying again with
the same name updates the existing workflow.

## Testing

```bash
npm run typecheck   # tsc --noEmit (needs shared/offchain deps installed)
bun test            # workflow.test.ts
```
