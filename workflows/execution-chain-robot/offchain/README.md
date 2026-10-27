# ExecutionChainRobot — CRE workflow

Off-chain CRE workflow driving [`ExecutionChainRobotReceiver`](../src/ExecutionChainRobotReceiver.sol).
Every 10 minutes (`GOVERNANCE_SCHEDULE`), per chain, it calls the receiver's `checkUpkeep`
(empty `checkData`) and writes one report `abi.encode(uint40[] [payloadId])` to `onReport` for
each payload returned, so a payload that reverts doesn't block the others.

Each write goes through the shared `submitReport`
([`checkUpkeep.ts`](../../shared/offchain/checkUpkeep.ts)): a payload whose `onReport`
estimate reverts, or doesn't fit the write gas quota once the forwarder's overhead is added
(`requiredWriteGas`), is skipped with a log, since it would fail and be retried every tick. A
write whose `onReport` reverted inside the forwarder tx is logged as failed.

## Config

One entry per chain in [`config.production.json`](config.production.json), matching
`DeployExecutionChainRobotReceiver` (checked by its test). `receiver` is set after each
deploy; chains without one get no trigger. 8 chains is within CRE's 10 triggers per workflow.

## Setup

```bash
cd workflows/execution-chain-robot/offchain && npm install   # or `make install` from repo root
```

## Simulate / deploy

```bash
# from workflows/ (the directory with project.yaml)
cre workflow simulate ./execution-chain-robot/offchain --env=../.env --target=execution-chain-robot-production-settings --non-interactive --trigger-index=0

# --unsigned prints the tx for the owner Safe to propose (does not broadcast)
cre workflow deploy   ./execution-chain-robot/offchain --env=../.env --target=execution-chain-robot-production-settings --unsigned
cre workflow activate ./execution-chain-robot/offchain --env=../.env --target=execution-chain-robot-production-settings --unsigned --yes
```

`--trigger-index` selects the chain among those with a `receiver`. The same commands are
`package.json` scripts (`npm run simulate:production`, …). Deploying again with the same
`workflow-name` ([`workflow.yaml`](workflow.yaml)) updates the workflow.

## Testing

```bash
npm run typecheck   # tsc --noEmit (needs shared/offchain deps installed)
bun test            # workflow.test.ts
```
