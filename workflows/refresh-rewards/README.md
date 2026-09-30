# RefreshRewards

CRE robot that registers reward tokens on Aave v3 stataTokens (static aTokens)
when a reward is configured on the underlying aToken **after** the stataToken was
created. stataTokens don't pick up rewards added later: until someone calls the
permissionless `refreshRewardTokens()`, that reward's emissions aren't distributed
to stataToken holders (registration starts accounting from the current index).
This robot calls it as soon as the reward shows up.

## Layout

```
refresh-rewards/
├── src/
│   ├── RefreshRewardsReceiver.sol        # the robot — inherits IAaveCREReceiver, permissionless onReport
│   └── IRefreshRewardsReceiver.sol       # robot interface
├── tests/
│   ├── RefreshRewardsReceiver.t.sol      # unit tests (vm.mockCall against factory/controller/stata)
│   ├── RefreshRewardsReceiver.fork.t.sol # fork tests against the live factories of every covered chain
│   ├── DeployRefreshRewardsReceiver.t.sol # per-chain deploy config vs offchain config
│   └── helpers/
│       └── RefreshRewardsReceiverHarness.sol
├── scripts/
│   └── DeployRefreshRewardsReceiver.s.sol # stand-alone forge deploy
└── offchain/                             # CRE workflow — see offchain/README.md
```

## On-chain behavior

`RefreshRewardsReceiver` implements [`IAaveCREReceiver`](../shared/src/IAaveCREReceiver.sol):

- `checkUpkeep(factory) → (needed, (factory, stataTokens[]))` — read-only probe.
  Enumerates `factory.getStataTokens()` and flags each stataToken whose
  `INCENTIVES_CONTROLLER` lists a reward for its aToken that isn't registered yet,
  up to `MAX_ACTIONS` (10) per tick. Returns false if the factory isn't enabled.
- `onReport(metadata, (factory, stataTokens[]))` — calls `refreshRewardTokens()`
  on each stataToken that still needs it. Skips any stataToken the factory didn't
  deploy (`factory.getStataToken(stata.asset()) != stata`). Reverts
  `ConditionsNotMet` if the factory isn't enabled or nothing was refreshed.

The controller is read from each stataToken (`INCENTIVES_CONTROLLER`), the same
one `refreshRewardTokens()` uses.

`onReport` is **permissionless**: `metadata` and `msg.sender` are ignored. It only
acts on stataTokens deployed by an enabled factory, and `refreshRewardTokens()` is
permissionless itself, so restricting who delivers the report adds no security.
No on-chain role is required.

### State and access control

- `_enabled[factory]` — allowlist of stataToken factories the robot acts on. New
  stataTokens from an enabled factory are covered without any extra action.
- The initial allowlist is set in the constructor.
- `enableFactory(factory)` — owner-only. Reverts `InvalidFactory` for the zero
  address and `FactoryStatusUnchanged` if already enabled.
- `disableFactory(factory)` — owner or guardian (emergency off-switch). Reverts
  `FactoryStatusUnchanged` if not enabled.
- Both emit `FactoryStatusUpdated(factory, enabled)`.
- The contract is `Rescuable`; the owner is the rescue guardian.

## Configuration

One receiver per chain, with that chain's stataToken factories (e.g. Ethereum Core
and Lido) in [`offchain/config.production.json`](offchain/config.production.json).
Factory addresses come from `aave-address-book` (`STATA_FACTORY`).

Covered chains are the ones whose stataTokens have had rewards configured in the
`RewardsController`: Ethereum (Core and Lido), Avalanche, Optimism, Arbitrum and
Base. Adding one is a `getDeployConfig` entry, a config entry and a deploy.

## Testing

```bash
# from repo root
forge test --match-path 'workflows/refresh-rewards/tests/*.t.sol' --no-match-contract 'Fork' -vvv   # unit
forge test --match-contract 'RefreshRewardsReceiverFork' -vvv   # fork; needs RPC_MAINNET/AVALANCHE/OPTIMISM/ARBITRUM/BASE
cd workflows/refresh-rewards/offchain && bun test                                                    # CRE workflow (bun)
```

The fork suite checks every factory the deploy script enables on its chain, and
runs a real refresh on Ethereum by appending a new reward to one aToken's list.

`workflow.test.ts` runs `createFactoryHandler` against a mocked cre-sdk EVM client
(`EvmMock`) for each branch. Requires `bun` on PATH.

## Deployment

`RefreshRewardsReceiver` deploys stand-alone, one per chain.
`DeployRefreshRewardsReceiver` picks the config from `block.chainid`: the chain's
`GovernanceV3<Chain>.EXECUTOR_LVL_1` / `GOVERNANCE_GUARDIAN` as owner / guardian,
and its `STATA_FACTORY` (plus `AaveV3EthereumLido.STATA_FACTORY` on Ethereum)
enabled in the constructor. `DeployRefreshRewardsReceiver.t.sol` checks these
factories match `offchain/config.production.json`.

```bash
# from repo root, with ACCOUNT_NAME=<your-keystore-name> in .env
# env: Mainnet, Avalanche, Optimism, Arbitrum or Base
make deploy-refresh-rewards env=Avalanche dry=true   # simulate
make deploy-refresh-rewards env=Avalanche            # broadcast
```

### Post-deploy

1. Set the deployed address as `receiver` for that chain in
   [`offchain/config.production.json`](offchain/config.production.json).
2. (Re)deploy the CRE workflow through the owner Safe — see
   [`offchain/README.md`](offchain/README.md).

Post-deploy checks (substitute the deployed `<receiver>`):

```bash
cast call <receiver> "owner()(address)" --rpc-url <chain>
cast call <receiver> "guardian()(address)" --rpc-url <chain>
cast call <receiver> "isFactoryEnabled(address)(bool)" <factory> --rpc-url <chain>
```
