# ExecutionChainRobot

CRE robot that executes Aave Governance V3 payloads once they are queued in a chain's
`PayloadsController` and their timelock has passed. Native CRE port of BGD Labs'
[`ExecutionChainRobotKeeper`](https://github.com/bgd-labs/aave-governance-v3-robots/blob/main/src/contracts/ExecutionChainRobotKeeper.sol)
and, on Ethereum, of
[`GasCappedExecutionChainRobotKeeper`](https://github.com/bgd-labs/aave-governance-v3-robots/blob/main/src/contracts/gasprice-capped-robots/GasCappedExecutionChainRobotKeeper.sol),
which only acts while the network gas price is under a cap. One receiver per chain:
Ethereum, Avalanche, Polygon, Optimism, Arbitrum, Base, BNB and Plasma.

## Layout

```
execution-chain-robot/
├── src/
│   ├── ExecutionChainRobotReceiver.sol         # the robot — inherits IAaveCREReceiver, permissionless onReport
│   └── IExecutionChainRobotReceiver.sol        # robot interface
├── tests/
│   ├── ExecutionChainRobotReceiver.t.sol       # unit tests (vm.mockCall against the PayloadsController / gas feed)
│   ├── ExecutionChainRobotReceiver.fork.t.sol  # fork tests executing a real payload on every chain
│   ├── DeployExecutionChainRobotReceiver.t.sol # per-chain deploy config vs offchain config
│   └── helpers/
│       └── ExecutionChainRobotReceiverHarness.sol
├── scripts/
│   └── DeployExecutionChainRobotReceiver.s.sol # stand-alone forge deploy, config per chainId
└── offchain/                                   # CRE workflow — see offchain/README.md
```

## On-chain behavior

`ExecutionChainRobotReceiver` implements [`IAaveCREReceiver`](../shared/src/IAaveCREReceiver.sol),
with the same decision logic as BGD's keeper:

- `checkUpkeep(_) → (needed, uint40[] payloadIds)` — read-only probe. Returns false while
  the gas price is above the cap. Otherwise walks back from the latest payload and
  collects the executable ones (`Queued`, not expired, and `block.timestamp > queuedAt + delay`,
  the condition `executePayload` enforces), up to `MAX_ACTIONS` (5). It stops after
  `MAX_SKIP` + 1 (21) consecutive non-executable payloads; finding an executable one resets
  that count and disabled payloads are not counted. Ids are returned oldest first.
  `checkData` is unused: the PayloadsController is an immutable of the contract.
- `onReport(metadata, uint40[] payloadIds)` — calls `PAYLOADS_CONTROLLER.executePayload`
  for each payload that is not disabled and still executable, in report order, emitting
  `ActionSucceeded(id)`. Reverts `NoActionCanBePerformed` if none was executed.

`onReport` is **permissionless**: `metadata` and `msg.sender` are ignored.
`executePayload` is permissionless itself and only runs payloads governance queued, so
restricting who delivers the report adds no security. No on-chain role is required.

### Gas price cap

A receiver deployed with a gas price oracle (Ethereum only) returns false from
`checkUpkeep` while the oracle's `latestAnswer()` is above `getMaxGasPrice()`, the same
check as BGD's `GasCappedRobotBase` (no staleness check, a negative answer counts as above
the cap). The oracle is Chainlink's
[Fast Gas / Gwei](https://etherscan.io/address/0x169E633A2D1E6c10dD91238Ba11c4A708dfEF37C)
feed (in wei, despite the name) and the initial cap is 150 gwei, both as on the live BGD
keeper. Like BGD's keeper, `onReport` doesn't check the cap. On the other chains the oracle
is the zero address and there is no cap.

### Differences with BGD's keeper

- BGD's `checkUpkeep` shuffles up to 5 executable payloads with `blockhash` and returns one,
  so a payload whose execution reverts doesn't always block the others. CRE nodes may read
  different blocks, so `checkUpkeep` returns all of them, oldest first, and the workflow
  writes one report per payload: a reverting payload fails its own `estimateGas` and is
  skipped without blocking the rest.
- The workflow also skips (and logs) any payload whose `onReport` estimate is above the CRE
  write gas quota; it has to be executed manually (`executePayload` is permissionless).
- BGD's owner-only `toggleDisableAutomationById` becomes `disablePayload` (owner or
  guardian) / `enablePayload` (owner), which revert when the status doesn't change, and
  `onReport` also skips disabled payloads.
- `setMaxGasPrice` is owner or guardian (BGD: owner-only), and reverts when the cap doesn't
  change and on a receiver without oracle.

### State and access control

- `_disabled[payloadId]` — payloads excluded from automation. Payloads are covered by
  default: governance creates new ones continuously, and the robot's job is to execute
  every queued one, so this is a blocklist for the exception (e.g. a payload that keeps
  reverting).
- `disablePayload(payloadId)` — owner or guardian. Reverts `PayloadStatusUnchanged` if
  already disabled.
- `enablePayload(payloadId)` — owner-only. Reverts `PayloadStatusUnchanged` if not
  disabled.
- Both emit `PayloadDisabled(payloadId, disabled)`.
- `setMaxGasPrice(maxGasPrice)` — owner or guardian, so the cap can follow the gas market
  without a governance vote. Reverts `MaxGasPriceUnchanged` if equal to the current cap and
  `GasPriceCapNotSupported` without an oracle. Emits `MaxGasPriceSet`.
- The contract is `Rescuable`; the owner is the rescue guardian.

## Testing

```bash
# from repo root
forge test --match-path 'workflows/execution-chain-robot/tests/*.t.sol' --no-match-contract 'Fork' -vvv   # unit
forge test --match-contract 'ExecutionChainRobotReceiverFork' -vvv   # fork; needs RPC_MAINNET/AVALANCHE/POLYGON/OPTIMISM/ARBITRUM/BASE/BNB (+ RPC_PLASMA)
cd workflows/execution-chain-robot/offchain && bun test                                                 # CRE workflow (bun)
```

On every chain, the fork suite runs the deploy script, creates a payload on the live
`PayloadsController`, queues it as the chain's `CrossChainController` delivers a passed
proposal from Ethereum governance, and checks the robot only picks it once its delay has
passed and executes it. It also checks the receiver agrees with BGD's live keeper, on every chain but Plasma (same
`PayloadsController`, same `upkeepNeeded`, BGD's pick among the receiver's ids), the
Ethereum gas cap against BGD's, and that an expired payload is skipped. On Ethereum, the
harness's `canPayloadBeExecuted` is checked against the live `executePayload` at each
timelock and expiry boundary. The Plasma case is skipped without `RPC_PLASMA` (the public
`https://rpc.plasma.to` works).

`workflow.test.ts` runs `createReceiverHandler` against a mocked cre-sdk EVM client
(`EvmMock`) for each branch. Requires `bun` on PATH.

## Deployment

`ExecutionChainRobotReceiver` deploys stand-alone, one per chain.
`DeployExecutionChainRobotReceiver` picks the config from `block.chainid`: the chain's
`GovernanceV3<Chain>.PAYLOADS_CONTROLLER`, with `EXECUTOR_LVL_1` / `GOVERNANCE_GUARDIAN` as
owner / guardian, plus the gas cap on Ethereum. It reverts on any other chain.
`DeployExecutionChainRobotReceiver.t.sol` checks the chains match
`offchain/config.production.json`.

Monad is not covered: the pinned `aave-address-book` has no `GovernanceV3Monad`. Adding it
takes its `PAYLOADS_CONTROLLER`, `EXECUTOR_LVL_1` and `GOVERNANCE_GUARDIAN` (hardcoded from
upstream, as the GSM freezer does, or an address book bump), a `monad-mainnet` config and
`project.yaml` entry with `RPC_MONAD`, and a fork case that only runs with `--network monad`
(forge needs Monad's EVM to fork it). The workflow would then have 9 of CRE's 10 triggers.

```bash
# from repo root, with ACCOUNT_NAME=<your-keystore-name> in .env
# env: Mainnet, Avalanche, Polygon, Optimism, Arbitrum, Base, BNB or Plasma
make deploy-execution-chain-robot env=Mainnet dry=1   # simulate
make deploy-execution-chain-robot env=Mainnet         # broadcast + verify
```

### Post-deploy

1. Set each deployed address as that chain's `receiver` in
   [`offchain/config.production.json`](offchain/config.production.json).
2. (Re)deploy the CRE workflow through the owner Safe — see
   [`offchain/README.md`](offchain/README.md).
3. Once it runs, stop forwarding BGD's keepers (the `Execution Chain Robot` entries of the
   legacy CRE automation workflow). Running both is harmless, the second execution of a
   payload just fails `estimateGas` and is skipped, but wastes reads.

No governance proposal is needed: the receiver needs no role. The Ethereum gas cap can
later be changed (`setMaxGasPrice`) by the guardian as well as the owner.

Post-deploy checks (substitute the deployed `<receiver>`):

```bash
cast call <receiver> "PAYLOADS_CONTROLLER()(address)" --rpc-url <chain>
cast call <receiver> "owner()(address)" --rpc-url <chain>
cast call <receiver> "guardian()(address)" --rpc-url <chain>
cast call <receiver> "getMaxGasPrice()(uint256)" --rpc-url mainnet
cast call <receiver> "checkUpkeep(bytes)(bool,bytes)" 0x --rpc-url <chain>
```
