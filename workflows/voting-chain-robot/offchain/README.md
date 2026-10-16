# Voting Chain Robot — CRE workflow

Off-chain CRE workflow driving [`VotingChainRobotReceiver`](../src/VotingChainRobotReceiver.sol)
on the three Governance V3 voting chains. Every 5 minutes, for each chain, it calls the
receiver's `checkUpkeep` with empty `checkData`; when an action is due it estimates
`onReport` with the returned `performData`, then signs it and writes it back as the
receiver's `onReport`. One cron trigger per chain (Ethereum, Avalanche, Polygon).

A CRE write carries at most 16,777,216 gas (`MAX_WRITE_GAS`, the current
`ChainWrite.EVM` quota): a report estimated above it is skipped and logged. A full batch
(5 actions) stays well below it; a `closeAndSendVote` costs about 1.1M gas.

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
