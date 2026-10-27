# Aave Depositor

CRE robot that puts idle Aave Collector funds to work: it supplies reserve balances
into the V3 pools and migrates residual V2 aTokens into V3, through the Aave
`PoolExposureSteward` behind a Zodiac Roles Modifier. Native CRE re-implementation of
the `bot-aave-depositor` workflow and its `AaveIntentExecutor`. One receiver and one
workflow per chain: Ethereum, Arbitrum, Base, Optimism, Avalanche and Polygon.

## Layout

```
aave-depositor/
├── src/
│   ├── AaveDepositorReceiver.sol         # the robot — inherits WorkflowsBase, permissioned onReport
│   └── IAaveDepositorReceiver.sol        # robot interface + minimal Roles / Steward interfaces
├── tests/
│   ├── AaveDepositorReceiver.t.sol       # unit tests (mocked Roles Modifier)
│   ├── AaveDepositorReceiver.fork.t.sol  # fork test: AFC grants the role, a real depositV3 runs
│   └── AaveDepositorReceiverAvalanchePolygon.fork.t.sol  # fork test: AFC scopes the role, deposit + migration
├── scripts/
│   ├── DeployAaveDepositorReceiver.s.sol # stand-alone forge deploy (any supported chain)
│   └── AaveDepositorNetworks.sol         # per-chain forwarder / Roles / Steward, shared with the fork tests
└── offchain/                             # CRE workflow — see offchain/README.md
```

## On-chain behavior

`AaveDepositorReceiver` inherits [`WorkflowsBase`](../shared/src/WorkflowsBase.sol):

- `checkUpkeep(checkData) → (needed, calls)` — read-only pre-flight. `checkData` is
  `abi.encode(bytes[] calls)`, each call being Steward calldata. Returns `(true,
checkData)` when automation is enabled and every call targets an allowed selector,
  `(false, "")` otherwise.
- `onReport(metadata, report)` — **permissioned**: `msg.sender` must be the CRE
  forwarder, and when `expectedWorkflowId` is set the report's workflow id must match.
  Decodes `report` as `bytes[]` and executes every call through
  `Roles.execTransactionWithRole(STEWARD, 0, call, CALL, ROLE_KEY, true)`, emitting
  `StewardCallExecuted` per call. All-or-nothing: any rejected call reverts the report.

### Why one call at a time

The `aave_depositor` role on the Roles Modifier is scoped to the Steward and allows
exactly two functions: `depositV3(address,address,uint256)` and
`migrateV2toV3(address,address,address,uint256)`. Roles validates the outer selector of
each transaction, so a `multicall` wrapper would be rejected. The robot enforces the
same two selectors itself and forwards calls individually.

### Why permissioned

These calls move Collector funds. Restricting delivery to the forwarder (and optionally
to one workflow id) means only a DON-signed report from the trusted workflow can trigger
them; the Roles Modifier then limits what that report can do.

### State

- `expectedWorkflowId` — zero accepts any workflow; set via `setExpectedWorkflowId`, owner only.
- The global automation switch from `WorkflowsBase`: `disableAutomation()` (owner or
  guardian) makes `checkUpkeep` report no upkeep and `onReport` revert,
  `enableAutomation()` (owner) resumes.

The contract never holds tokens (the Steward moves them Collector → pool); the owner can
still rescue anything sent to it by mistake through the base's `Rescuable`.

## Prerequisites on each chain

Deploying the receiver is not enough. On Ethereum the Roles Modifier
(`0x1D5579B363806CCecc35115ab8F56EECf6610ea9`) is owned by, and executes through, the
Aave Finance Committee Safe (`MiscEthereum.AFC_SAFE`), which must:

1. `enableModule(rolesModifier)` on the Safe itself (as of 2026-09-24 this is done on
   Arbitrum, Base and Optimism but **not** on Ethereum, where every role reverts with
   `GS104`);
2. `enableModule(receiver)` on the Roles Modifier;
3. `assignRoles(receiver, [bytes32("aave_depositor")], [true])` on the Roles Modifier.

Until then `onReport` reverts. The fork test performs all three by impersonating the Safe.

On Avalanche (`0x5B9829172d39b6566f0A5f0E9BdD9D6DD6Ad3205`) and Polygon
(`0x395721158D0D0E8492B35d172cFb0A8a759173bd`) the AFC Roles Modifier is already enabled
on the Safe, but as of 2026-10-01 the `aave_depositor` role doesn't allow the Steward:
calls revert with `ConditionViolation(FunctionNotAllowed)`. On top of steps 2 and 3, the
Safe must scope the role:

- `scopeTarget(roleKey, steward)`;
- `allowFunction(roleKey, steward, depositV3.selector, 0)`;
- `allowFunction(roleKey, steward, migrateV2toV3.selector, 0)`.

`AaveDepositorReceiverAvalanchePolygon.fork.t.sol` checks the current role rejects the
call, applies that transaction, and runs a real deposit and V2 to V3 migration.

### Not yet supported

Monad, Plasma, Mantle and XLayer have no `PoolExposureSteward` in the address book (as
of 2026-10-02), and no AFC Roles Modifier, so the robot has nothing to call there. They
can be added to `AaveDepositorNetworks` once the Steward is deployed and the AFC sets up
the role.

## Testing

```bash
# from repo root
forge test --match-path 'workflows/aave-depositor/tests/*.t.sol' --no-match-contract 'Fork' -vvv   # unit
RPC_MAINNET=... forge test --match-contract 'AaveDepositorReceiverFork' -vvv                        # fork
make test-offchain-aave-depositor                                                                  # CRE workflow (bun)
```

## Deploying

One receiver per network. The script takes forwarder, Roles Modifier and Steward from
`AaveDepositorNetworks`, and owner (level-1 governance executor) and guardian (governance
guardian) from the shared `GovernanceOwners`, for the chain it runs on:

```bash
make deploy-aave-depositor env=Mainnet dry=1   # simulate
make deploy-aave-depositor env=Mainnet         # broadcast + verify
make deploy-aave-depositor env=Arbitrum
make deploy-aave-depositor env=Base
make deploy-aave-depositor env=Optimism
make deploy-aave-depositor env=Avalanche
make deploy-aave-depositor env=Polygon
```

After deploying, paste the address into that chain's `offchain/config.<chain>.json` as
`receiver`, ask the Roles owner to grant the role, and pin the workflow id once the
workflow is deployed.
