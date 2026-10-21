# Governance Chain Robot — CRE workflow

Off-chain CRE workflow driving
[`GovernanceChainRobotReceiver`](../src/GovernanceChainRobotReceiver.sol). Every 30 seconds
(`schedule`) it calls `checkUpkeep` (empty `checkData`) and, when an action is due:

1. estimates `onReport(0x, performData)` and skips the tick if it reverts, or if
   `estimate * 64 / 63 + WRITE_OVERHEAD_GAS` (250k, forwarder overhead) exceeds the CRE
   write quota `MAX_WRITE_GAS` (16,777,216);
2. signs `performData` and writes it with the full quota as gas limit, since `onReport`
   catches reverting calls and a batch estimate could leave one action out of gas;
3. logs a failure if the tx or the receiver's `onReport` reverted.

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
