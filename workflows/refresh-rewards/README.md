# RefreshRewards

CRE robot that registers reward tokens on Aave v3 stataTokens (static aTokens)
when a reward is configured on the underlying aToken **after** the stataToken was
created. stataTokens do not auto-track rewards added later, so their holders stop
accruing until someone calls the permissionless `refreshRewardTokens()`. This
robot detects that gap and calls it. Native CRE re-implementation of BGD Labs'
[`RefreshRewardsRobot`](https://github.com/bgd-labs/static-a-token-v3).

## Layout

```
refresh-rewards/
├── src/
│   ├── RefreshRewardsReceiver.sol        # the robot — inherits IAaveCREReceiver, permissionless onReport
│   └── IRefreshRewardsReceiver.sol       # robot interface + minimal stata/controller interfaces
├── tests/
│   ├── RefreshRewardsReceiver.t.sol      # unit tests (vm.mockCall against factory/controller/stata)
│   └── RefreshRewardsReceiver.fork.t.sol # fork tests against the live Ethereum STATA_FACTORY
├── scripts/
│   └── DeployRefreshRewardsReceiver.s.sol # stand-alone forge deploy
└── offchain/                             # CRE workflow — see offchain/README.md
```

## On-chain behavior

`RefreshRewardsReceiver` implements [`IAaveCREReceiver`](../shared/src/IAaveCREReceiver.sol):

- `checkUpkeep((factory, controller)) → (needed, (controller, stataTokens[]))` —
  read-only probe. Enumerates `factory.getStataTokens()`, and for each stataToken
  reads the rewards configured on its aToken (`controller.getRewardsByAsset`) and
  flags it if any reward is not yet registered (`isRegisteredRewardToken == false`),
  up to `MAX_ACTIONS` (10) per tick.
- `onReport(metadata, (controller, stataTokens[]))` — calls
  `refreshRewardTokens()` on each stataToken that still needs it (re-validated
  against `controller`, so a stale report can't force redundant refreshes).
  Reverts `ConditionsNotMet` if none did.

`onReport` is intentionally **permissionless**: `metadata` (workflow id / owner /
name) and `msg.sender` (the forwarder) are both ignored. Justification —
`refreshRewardTokens()` is itself permissionless on the stataToken (it only
registers rewards the rewards-controller already lists), so restricting who
delivers the report adds no security.

### State

- `_disabled[stataToken]` — excludes a stataToken from automation. `checkUpkeep`
  skips disabled tokens. Toggled via `setAutomationDisabled(stataToken, disabled)`,
  owner or guardian.

## Configuration

One `(factory, controller)` pair per Aave pool. A chain with several pools (e.g.
Ethereum Core + Prime) lists several; a single `RefreshRewardsReceiver` per chain
serves them all — the pool addresses ride in `checkData`, not the constructor.
See [`offchain/config.production.json`](offchain/config.production.json). Factory
and controller addresses come from `aave-address-book`
(`STATA_FACTORY` / `DEFAULT_INCENTIVES_CONTROLLER`).

## Testing

```bash
# from repo root
forge test --match-path 'workflows/refresh-rewards/tests/*.t.sol' --no-match-contract 'Fork' -vvv   # unit
RPC_MAINNET=... forge test --match-contract 'RefreshRewardsReceiverFork' -vvv                        # fork
cd workflows/refresh-rewards/offchain && bun test                                                    # CRE workflow (bun)
```

The fork suite forks Ethereum mainnet against the live
[`STATA_FACTORY`](https://etherscan.io/address/0xCb0b5cA20b6C5C02A9A3B2cE433650768eD2974F),
asserts the minimal local interfaces match the real deployed ABIs across the whole
read path, and exercises both the revert path (fully-registered token →
`ConditionsNotMet`) and the refresh path (scans for a stataToken with an
unregistered reward; skips if none is). It skips entirely when `RPC_MAINNET` is unset.

`workflow.test.ts` mocks the cre-sdk EVM client via `EvmMock` and drives
`createPoolHandler` end-to-end for each branch (no refresh, empty/reverting
`checkUpkeep`, gas-estimate revert, happy path, non-SUCCESS write). Generic helpers
(`encodeCheckUpkeepResult`, `CHECK_UPKEEP_SELECTOR`) live in
[`../shared/offchain/testing/mocks.ts`](../shared/offchain/testing/mocks.ts).
Requires `bun` on PATH.

## Deployment

`RefreshRewardsReceiver` deploys stand-alone. `DeployRefreshRewardsReceiver` uses
`GovernanceV3Ethereum.EXECUTOR_LVL_1` as owner and
`GovernanceV3Ethereum.GOVERNANCE_GUARDIAN` as guardian; adapt for other chains.

```bash
# from repo root, with ACCOUNT_NAME=<your-keystore-name> in .env
forge script workflows/refresh-rewards/scripts/DeployRefreshRewardsReceiver.s.sol \
  --rpc-url mainnet --account $ACCOUNT_NAME --broadcast --verify
```

### Post-deploy

1. Set the deployed address as `receiver` for that chain in
   [`offchain/config.production.json`](offchain/config.production.json).
2. (Re)deploy the CRE workflow through the owner Safe — see
   [`offchain/README.md`](offchain/README.md).

No on-chain role is required — `refreshRewardTokens()` is permissionless.

Post-deploy checks (substitute the deployed `<receiver>`):

```bash
cast call <receiver> "owner()(address)" --rpc-url mainnet
cast call <receiver> "guardian()(address)" --rpc-url mainnet
cast call <receiver> "MAX_ACTIONS()(uint256)" --rpc-url mainnet
```
