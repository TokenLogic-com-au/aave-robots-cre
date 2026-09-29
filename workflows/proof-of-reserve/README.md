# ProofOfReserve

CRE robot that runs an Aave [Proof of Reserve](https://github.com/aave-dao/aave-proof-of-reserve)
executor's emergency action when a reserve becomes unbacked, freezing the
affected reserves. Replaces BGD Labs' `ProofOfReserveKeeper`. Avalanche only.

## Layout

```
proof-of-reserve/
├── src/
│   ├── ProofOfReserveReceiver.sol        # the robot — inherits IAaveCREReceiver, permissionless onReport
│   └── IProofOfReserveReceiver.sol       # robot interface + minimal executor interface
├── tests/
│   ├── ProofOfReserveReceiver.t.sol      # unit tests (vm.mockCall against the executor)
│   ├── ProofOfReserveReceiver.fork.t.sol # fork tests against the live Avalanche executors
│   └── helpers/
│       └── ProofOfReserveReceiverHarness.sol
├── scripts/
│   └── DeployProofOfReserveReceiver.s.sol # stand-alone forge deploy
└── offchain/                             # CRE workflow — see offchain/README.md
```

## On-chain behavior

`ProofOfReserveReceiver` implements [`IAaveCREReceiver`](../shared/src/IAaveCREReceiver.sol):

- `checkUpkeep(executor) → (needed, executor)` — read-only probe. Returns true when
  the executor is enabled for automation, not all of its reserves are backed
  (`!areAllReservesBacked()`), and the emergency action would change state
  (`isEmergencyActionPossible()`). `checkData` is `abi.encode(address executor)`.
- `onReport(metadata, executor)` — re-validates the executor and calls
  `executeEmergencyAction()`. Reverts `EmergencyActionNotPossible` if the executor
  is no longer actionable.

`onReport` is **permissionless**: `metadata` and `msg.sender` are ignored. It only
acts on allowlisted executors, and `executeEmergencyAction` is permissionless
itself, so restricting who delivers the report adds no security. No on-chain role
is required.

### State

- `_enabled[executor]` — allowlist of executors the robot acts on. `checkUpkeep`
  returns false and `onReport` reverts `EmergencyActionNotPossible` for any executor
  not on the list.
- The initial allowlist is set in the constructor.
- `enableExecutor(executor)` — owner-only. Reverts `InvalidExecutor` for the zero
  address and `ExecutorStatusUnchanged` if already enabled.
- `disableExecutor(executor)` — owner or guardian (emergency off-switch). Reverts
  `ExecutorStatusUnchanged` if not enabled.
- Both emit `ExecutorStatusUpdated(executor, enabled)`.
- The contract is `Rescuable`; the owner is the rescue guardian.

## Configuration

The workflow runs every 30 seconds (`*/30 * * * * *`, the CRE cron minimum).

One entry per executor. The Avalanche executors are the V2 and V3 Proof of Reserve
executors — see [`offchain/config.production.json`](offchain/config.production.json).
Addresses come from `aave-address-book` (`AaveV2Avalanche.PROOF_OF_RESERVE` /
`AaveV3Avalanche.PROOF_OF_RESERVE`).

## Testing

```bash
# from repo root
forge test --match-path 'workflows/proof-of-reserve/tests/*.t.sol' --no-match-contract 'Fork' -vvv   # unit
RPC_AVALANCHE=... forge test --match-contract 'ProofOfReserveReceiverFork' -vvv                       # fork
cd workflows/proof-of-reserve/offchain && bun test                                                    # CRE workflow (bun)
```

The fork suite forks Avalanche against the live V2/V3 executors, asserts the
minimal local interface matches the real deployed ABIs, and exercises the revert
path (a backed, enabled executor → `EmergencyActionNotPossible`). It fails if no
executor is currently backed.

`workflow.test.ts` mocks the cre-sdk EVM client via `EvmMock` and drives
`createExecutorHandler` end-to-end for each branch. Generic helpers
(`encodeCheckUpkeepResult`, `CHECK_UPKEEP_SELECTOR`) live in
[`../shared/offchain/testing/mocks.ts`](../shared/offchain/testing/mocks.ts).
Requires `bun` on PATH.

## Deployment

`ProofOfReserveReceiver` deploys stand-alone. `DeployProofOfReserveReceiver` uses
`GovernanceV3Avalanche.EXECUTOR_LVL_1` / `GOVERNANCE_GUARDIAN` as owner / guardian
and enables `AaveV2Avalanche.PROOF_OF_RESERVE` / `AaveV3Avalanche.PROOF_OF_RESERVE`
in the constructor.

```bash
# from repo root, with ACCOUNT_NAME=<your-keystore-name> in .env
make deploy-proof-of-reserve env=Avalanche dry=true   # simulate
make deploy-proof-of-reserve env=Avalanche            # broadcast
```

### Post-deploy

1. Set the deployed address as `receiver` in
   [`offchain/config.production.json`](offchain/config.production.json).
2. (Re)deploy the CRE workflow through the owner Safe — see
   [`offchain/README.md`](offchain/README.md).

Post-deploy checks (substitute the deployed `<receiver>`):

```bash
cast call <receiver> "owner()(address)" --rpc-url avalanche
cast call <receiver> "guardian()(address)" --rpc-url avalanche
cast call <receiver> "isExecutorEnabled(address)(bool)" <executor> --rpc-url avalanche
```
