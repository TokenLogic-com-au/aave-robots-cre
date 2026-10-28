# ExecutionChainRobot

CRE robot that executes Aave Governance V3 payloads once they are queued in a chain's
`PayloadsController` and their timelock has passed. Native CRE port of BGD Labs'
[`ExecutionChainRobotKeeper`](https://github.com/bgd-labs/aave-governance-v3-robots/blob/main/src/contracts/ExecutionChainRobotKeeper.sol)
and, on Ethereum, its gas-capped variant. One receiver per chain: Ethereum, Avalanche,
Polygon, Optimism, Arbitrum, Base, BNB and Plasma. BGD's other chains and Monad (not in the
pinned `aave-address-book`) aren't covered yet; each is a `getDeployConfig` branch, a config
entry and an RPC.

## Layout

```
execution-chain-robot/
├── src/
│   ├── ExecutionChainRobotReceiver.sol         # the robot — GasCappedWorkflowsBase + IdDenylist, permissionless onReport
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

`ExecutionChainRobotReceiver` inherits [`GasCappedWorkflowsBase`](../shared/src/GasCappedWorkflowsBase.sol)
and [`IdDenylist`](../shared/src/IdDenylist.sol), and implements `_checkUpkeep` / `_onReport`:

- `checkUpkeep(_) → (needed, uint40[] payloadIds)` — read-only probe. Returns false while
  automation is disabled or the gas price is above the cap. Otherwise walks back from the
  latest payload collecting executable ones (`Queued`, not expired and past
  `queuedAt + delay`, as `executePayload` requires), oldest first, up to `MAX_ACTIONS` (5). It
  stops after `MAX_SKIP` + 1 (21) consecutive non-executable payloads (queued in their
  timelock, executed, cancelled or expired; an executable one resets the count) or
  `MAX_SCANNED_PAYLOADS` (100) scanned. Disabled and `Created` payloads aren't counted, and
  each state read gets at most `MAX_STATE_READ_GAS` (150k).
- `onReport(metadata, uint40[] payloadIds)` — calls `PAYLOADS_CONTROLLER.executePayload` for
  each payload in the report still executable and not disabled, in report order, emitting
  `ActionSucceeded(id)`. Reverts `NoActionCanBePerformed` if none was executed, and
  `AutomationIsDisabled` while the robot is disabled. It executes exactly the ids it is given,
  so a caller can split a batch across reports.

`onReport` is **permissionless**: `metadata` and `msg.sender` are ignored. `executePayload`
is permissionless itself and only runs payloads governance queued. No on-chain role is
required.

The Ethereum receiver is gas capped: `checkUpkeep` returns false while Chainlink's
[Fast Gas](https://etherscan.io/address/0x169E633A2D1E6c10dD91238Ba11c4A708dfEF37C) feed
(in wei) is above `getMaxGasPrice()` (150 gwei at deploy) or negative. `onReport` doesn't
check it. Other chains have no oracle and no cap.

### Differences with BGD's keeper

- BGD shuffles the executable payloads with `blockhash` and executes one per upkeep. CRE
  nodes may read different blocks, so `checkUpkeep` returns all of them and the workflow
  writes one report per payload: a reverting payload only fails its own `estimateGas`.
- `createPayload` is permissionless, so BGD's scan can be stopped short by 21 junk payloads
  created after a queued one. Here `Created` payloads don't count toward `MAX_SKIP`, only
  queued payloads are loaded in full, and a state read that doesn't fit `MAX_STATE_READ_GAS`
  (junk with large actions) is skipped. `MAX_SCANNED_PAYLOADS` bounds `checkUpkeep`: measured
  on an Arbitrum fork with cold storage, 541k gas for the live payloads, 2.2M with 100 minimal
  junk payloads and ~15M worst case (100 junk payloads at the 150k read cap). The residual
  limit: more than 100 junk payloads created after a queued one still hide it until they
  expire (35 days); it can be executed manually or by a report.
- The workflow skips payloads too large for the CRE write gas quota; those need a manual
  `executePayload`.
- `disableAutomation` / `setMaxGasPrice` are also open to the guardian, setters revert when
  nothing changes, `onReport` skips disabled payloads, and the whole robot can be switched
  off.

### State and access control

Owner / guardian access control, the global switch, the gas cap and the per-payload denylist
come from the shared base (see the [root README](../../README.md)):

- `disableAutomation()` (owner or guardian) / `enableAutomation()` (owner) — stops / resumes
  the whole robot.
- `disableId(id)` (owner or guardian) / `enableId(id)` (owner) — excludes a
  single payload, e.g. one that keeps reverting. Every payload is covered by default, since
  governance keeps creating them.
- `setMaxGasPrice(maxGasPrice)` — owner or guardian, so the cap can follow the gas market
  without a vote. `setMaxGasPrice(0)` stops `checkUpkeep` on Ethereum (the constructor rejects
  0 to catch deploy mistakes). Reverts `GasPriceCapNotSupported` without an oracle.
- The contract is `Rescuable`; the owner is the rescue guardian.

## Testing

```bash
# from repo root
forge test --match-path 'workflows/execution-chain-robot/tests/*.t.sol' --no-match-contract 'Fork' -vvv   # unit (base contracts: workflows/shared/tests)
forge test --match-contract 'ExecutionChainRobotReceiverFork' -vvv   # fork; needs RPC_<CHAIN> (Plasma skipped without RPC_PLASMA)
cd workflows/execution-chain-robot/offchain && bun test                                                 # CRE workflow (bun)
```

On every chain, the fork suite runs the deploy script, creates a payload on the live
`PayloadsController`, queues it as the `CrossChainController` delivers a passed proposal, and
checks the robot picks it only after its delay and executes it, agreeing with BGD's live
keeper where there is one. The Fast Gas feed is mocked, so results don't depend on live gas.
It also checks that 30+ junk payloads (one too large to read) created on Polygon after a
queued payload don't hide it, the gas cap, that expired payloads are skipped, and the harness's
`canPayloadBeExecuted` against `executePayload` at each timelock and expiry boundary.

## Deployment

`DeployExecutionChainRobotReceiver` picks the config from `block.chainid`: the chain's
`GovernanceV3<Chain>.PAYLOADS_CONTROLLER`, the owner / guardian from `GovernanceOwners` (the
chain's `EXECUTOR_LVL_1` / `GOVERNANCE_GUARDIAN`), and the gas cap on Ethereum. It reverts on any other chain.

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
3. Stop forwarding BGD's keepers from the legacy CRE automation workflow. Running both is
   harmless: the second execution just fails `estimateGas`.

No governance proposal is needed, the receiver needs no role.

```bash
cast call <receiver> "PAYLOADS_CONTROLLER()(address)" --rpc-url <chain>
cast call <receiver> "owner()(address)" --rpc-url <chain>
cast call <receiver> "guardian()(address)" --rpc-url <chain>
cast call <receiver> "getMaxGasPrice()(uint256)" --rpc-url mainnet
```
