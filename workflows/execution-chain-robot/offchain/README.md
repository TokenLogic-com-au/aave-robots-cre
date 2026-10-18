# ExecutionChainRobot — CRE workflow

Off-chain CRE workflow driving [`ExecutionChainRobotReceiver`](../src/ExecutionChainRobotReceiver.sol)
on every covered chain. On each cron tick (every 30 seconds, like the legacy CRE automation
of BGD's keepers), for each chain it calls the receiver's `checkUpkeep` (with empty
`checkData`) and, for every payload id returned, writes a separate report
`abi.encode(uint40[] [payloadId])` to the receiver's `onReport`.

One report per payload means a payload whose execution reverts only fails its own
`estimateGas` and doesn't block the others.

## Gas

Each report's `onReport` is estimated first. A revert skips that payload with a log. An
estimate above `MAX_WRITE_GAS` (16,777,216, the CRE `ChainWrite.EVM` gas quota) is also
skipped with a log, since the write would fail and be retried on every tick; such a payload
has to be executed manually (`executePayload` is permissionless). The write requests the
full quota as gas limit, so the simulator and production behave the same; only the gas
used is paid.

## Config

One entry per chain in [`config.production.json`](config.production.json), in the order of
`DeployExecutionChainRobotReceiver.getDeployConfig` (checked by
`DeployExecutionChainRobotReceiver.t.sol`). `receiver` is filled in after the contract is
deployed on that chain. Chains with an empty `receiver` get no trigger, so the workflow can
only be simulated once at least one receiver is set. 8 chains is within CRE's limit of 10
triggers per workflow.

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

`--trigger-index` selects the chain, in config order among those with a `receiver`. Or via
the `package.json` scripts (`npm run simulate:production`, `npm run deploy:production:unsigned`,
…). The workflow name is set in [`workflow.yaml`](workflow.yaml)
(`execution-chain-robot-production`). Deploying again with the same name updates the
existing workflow.

## Testing

```bash
npm run typecheck   # tsc --noEmit (needs shared/offchain deps installed)
bun test            # workflow.test.ts
```
