# Mint To Treasury

CRE robot that calls `IPool.mintToTreasury` on every live Aave v3 pool once the USD value
of the reserve factor accrued to the treasury crosses a per-pool threshold. Replaces the
EOA crons that run it today. One receiver per network, all pools of the network minted in
one report.

## Layout

```
mint-to-treasury/
├── src/
│   ├── MintToTreasuryReceiver.sol         # the robot — inherits WorkflowsBase, permissionless onReport
│   └── IMintToTreasuryReceiver.sol        # robot interface
├── tests/
│   ├── MintToTreasuryReceiver.t.sol       # unit tests (vm.mockCall against the pool and oracle)
│   ├── MintToTreasuryReceiver.fork.t.sol  # fork tests: real mints on Arbitrum, Ethereum (4 pools) and Monad
│   ├── DeployMintToTreasuryReceiver.t.sol # deploy script and offchain configs cover the same chains
│   └── helpers/MockPoolHelpers.sol
├── scripts/
│   └── DeployMintToTreasuryReceiver.s.sol # stand-alone forge deploy, pools per chain
└── offchain/                              # CRE workflows — see offchain/README.md
```

## On-chain behavior

`MintToTreasuryReceiver` inherits [`WorkflowsBase`](../shared/src/WorkflowsBase.sol):

- `checkUpkeep(checkData) → (needed, pools)` — read-only probe. `checkData` is
  `abi.encode(address[] pools)`; returns the pools that can be minted as
  `abi.encode(address[])`, or `(false, "")` while automation is disabled, with empty
  `checkData`, or when none qualifies.
- `onReport(metadata, report)` — decodes `report` as `address[]` and, for each pool that
  can still be minted, calls `mintToTreasury` with its reserves that have an amount accrued.
  Skips the others and reverts `ConditionsNotMet` if none was minted, so a stale report
  fails the workflow's gas estimate. Reverts `AutomationIsDisabled` while disabled.

A pool can be minted when its threshold is set and the accrued value reaches it. The value
sums, over the active reserves, `accruedToTreasury` (stored scaled, so converted with the
reserve's normalized income) priced by the pool's oracle. A reserve whose price reverts or
is zero counts as $0 but is still minted.

`onReport` is **permissionless**, like `mintToTreasury` itself: the worst a caller can do is
send the revenue to the Collector earlier. The robot needs no role on the pools.

### State

- Per-pool USD threshold, in the pool oracle's base currency (1e8 = $1). Set at deployment
  (no AIP needed to start), changed by `updateUsdThreshold` (owner). `disableMinting`
  (owner or guardian) stops a pool. 0 means not configured.
- The global automation switch from `WorkflowsBase`: `disableAutomation()` (owner or
  guardian) makes `checkUpkeep` report no upkeep and `onReport` revert,
  `enableAutomation()` (owner) resumes.

The contract never holds tokens (the pool mints aTokens to its Collector); the owner can
still rescue anything sent to it by mistake through the base's `Rescuable`.

## Networks

Ethereum (Core, Prime, EtherFi, Horizon), Arbitrum, Avalanche, BNB, Base, Celo, Gnosis,
Ink (Whitelabel), Linea, Mantle, MegaETH, Monad, Optimism, Plasma, Polygon, Scroll, Sonic,
X Layer and zkSync. **Metis and Soneium are not covered: CRE does not support them.**

## Testing

```bash
# from repo root
forge test --match-path 'workflows/mint-to-treasury/tests/*.t.sol' --no-match-contract 'Fork' -vvv     # unit
RPC_MAINNET=... RPC_ARBITRUM=... forge test --match-path 'workflows/mint-to-treasury/tests/*.fork.t.sol' -vvv # fork
FORK_MONAD=true RPC_MONAD=... forge test --network monad --match-contract 'MintToTreasuryMonadFork' -vvv     # Monad, opt-in
make test-offchain-mint-to-treasury                                                                       # CRE workflows (bun)
```

## Deploying

One receiver per network. The script enables the chain's pools at `INITIAL_USD_THRESHOLD`
($5,000) and takes owner (level-1 governance executor) and guardian (governance guardian)
from the shared `GovernanceOwners`. After deployment the owner is the executor, so changing
a threshold needs an AIP; the guardian can only disable a pool.

```bash
make deploy-mint-to-treasury env=Mainnet dry=1   # simulate
make deploy-mint-to-treasury env=Mainnet         # broadcast + verify
make deploy-mint-to-treasury env=Arbitrum        # and so on for each network above
```

After deploying, paste the address into that network's `receiver` in
`offchain/config.production-{1,2,3}.json`.
