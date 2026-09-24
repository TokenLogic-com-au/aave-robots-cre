# Aave Depositor

CRE robot that puts idle Aave Collector funds to work: it supplies reserve balances
into the V3 pools and migrates residual V2 aTokens into V3, through the Aave
`PoolExposureSteward` behind a Zodiac Roles Modifier. Native CRE re-implementation of
the `bot-aave-depositor` workflow and its `AaveIntentExecutor`. One receiver and one
workflow per chain; Ethereum first.

## Layout

```
aave-depositor/
├── src/
│   ├── AaveDepositorReceiver.sol         # the robot — inherits IAaveCREReceiver, permissioned onReport
│   └── IAaveDepositorReceiver.sol        # robot interface + minimal Roles / Steward interfaces
├── tests/
│   ├── AaveDepositorReceiver.t.sol       # unit tests (mocked Roles Modifier)
│   └── AaveDepositorReceiver.fork.t.sol  # fork test: AFC grants the role, a real depositV3 runs
├── scripts/
│   ├── DeployAaveDepositorReceiver.s.sol # stand-alone forge deploy (Ethereum)
│   └── AaveDepositorEthereum.sol         # forwarder / Roles / role key constants shared with the fork test
└── offchain/                             # CRE workflow — see offchain/README.md
```

## On-chain behavior

`AaveDepositorReceiver` implements [`IAaveCREReceiver`](../shared/src/IAaveCREReceiver.sol):

- `checkUpkeep(checkData) → (needed, calls)` — read-only pre-flight. `checkData` is
  `abi.encode(bytes[] calls)`, each call being Steward calldata. Returns `(true,
  checkData)` when the robot is enabled and every call targets an allowed selector,
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
- `_disabled` — excludes the robot from automation. `checkUpkeep` and `onReport` both stand
  down while set. Toggled via `setDisabled(disabled)`, owner or guardian.

The contract never holds tokens (the Steward moves them Collector → pool), so unlike
`FeeSharesMinter` it does not include `Rescuable`.

## Prerequisites on each chain

Deploying the receiver is not enough. On Ethereum the Roles Modifier
(`0x1D5579B363806CCecc35115ab8F56EECf6610ea9`) is owned by, and executes through, the
Aave Finance Committee Safe (`MiscEthereum.AFC_SAFE`), which must:

1. `enableModule(rolesModifier)` on the Safe itself (as of 2026-09-23 this is not done:
   `AFC_SAFE.isModuleEnabled(roles)` is `false`, so every role reverts with `GS104`);
2. `enableModule(receiver)` on the Roles Modifier;
3. `assignRoles(receiver, [bytes32("aave_depositor")], [true])` on the Roles Modifier.

Until then `onReport` reverts. The fork test performs all three by impersonating the Safe.

## Testing

```bash
# from repo root
forge test --match-path 'workflows/aave-depositor/tests/*.t.sol' --no-match-contract 'Fork' -vvv   # unit
RPC_MAINNET=... forge test --match-contract 'AaveDepositorReceiverFork' -vvv                        # fork
make test-offchain-aave-depositor                                                                  # CRE workflow (bun)
```

## Deploying

```bash
make deploy-aave-depositor env=Mainnet dry=1   # simulate
make deploy-aave-depositor env=Mainnet         # broadcast + verify
```

Constructor: forwarder (Chainlink KeystoneForwarder for the chain), Roles Modifier,
Steward, role key, owner (level-1 governance executor) and guardian (governance
guardian). After deploying, paste the address into `offchain/config.ethereum.json` as
`receiver`, ask the Roles owner to grant the role, and pin the workflow id once the
workflow is deployed.
