# Governance Chain Robot — CRE workflow

Off-chain CRE workflow driving
[`GovernanceChainRobotReceiver`](../src/GovernanceChainRobotReceiver.sol). Every 10 minutes
(`schedule`, the shared `GOVERNANCE_SCHEDULE`) it calls `checkUpkeep` (empty `checkData`) and,
when an action is due, hands `performData` to the shared `submitReport`
([`shared/offchain/checkUpkeep.ts`](../../shared/offchain/checkUpkeep.ts)), which estimates
`onReport`, skips the tick if it would revert or not fit the CRE write quota, and otherwise
writes the signed report without a `gasConfig`, so the DON applies its default limit (the
quota). The estimate is never the gas limit: with too little gas `onReport` can succeed while a Governance call or its a.DI forward
fails.

## Config

`receiver` is filled in after the receiver is deployed on Ethereum. With an empty
`receiver` the workflow has no trigger.

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
`npm run deploy:production:unsigned`, …). The workflow name is
`governance-chain-robot-production` ([`workflow.yaml`](workflow.yaml)).

## Testing

```bash
npm run typecheck   # tsc --noEmit (needs shared/offchain deps installed)
bun test            # workflow.test.ts
```
