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

`ExecutionChainRobotReceiver` implements [`IAaveCREReceiver`](../shared/src/IAaveCREReceiver.sol):

- `checkUpkeep(_) → (needed, uint40[] payloadIds)` — read-only probe. Returns false while
  the gas price is above the cap. Otherwise walks back from the latest payload collecting
  executable ones (`Queued`, not expired and past `queuedAt + delay`, as `executePayload`
  requires), oldest first, up to `MAX_ACTIONS` (5). It stops after `MAX_SKIP` + 1 (21)
  consecutive non-executable payloads; an executable one resets the count and disabled ones
  aren't counted.
- `onReport(metadata, uint40[] payloadIds)` — calls `PAYLOADS_CONTROLLER.executePayload` for
  each payload still executable and not disabled, emitting `ActionSucceeded(id)`. Reverts
  `NoActionCanBePerformed` if none was executed.

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
- The workflow skips payloads too large for the CRE write gas quota; those need a manual
  `executePayload`.
- `disableAutomation` / `setMaxGasPrice` are also open to the guardian, setters revert when
  nothing changes, and `onReport` skips disabled payloads.

### State and access control

- `_disabled[id]` — payloads excluded from automation. Every payload is covered by default,
  since governance keeps creating them; this is for the exception (e.g. one that keeps
  reverting).
- `disableAutomation(id)` — owner or guardian. `enableAutomation(id)` — owner-only. Both
  revert `AutomationStatusUnchanged` if the status wouldn't change and emit
  `AutomationDisabled(id, disabled)`.
- `setMaxGasPrice(maxGasPrice)` — owner or guardian, so the cap can follow the gas market
  without a vote. Reverts `MaxGasPriceUnchanged`, or `GasPriceCapNotSupported` without an
  oracle. Emits `MaxGasPriceSet`.
- The contract is `Rescuable`; the owner is the rescue guardian.

## Testing

```bash
# from repo root
forge test --match-path 'workflows/execution-chain-robot/tests/*.t.sol' --no-match-contract 'Fork' -vvv   # unit
forge test --match-contract 'ExecutionChainRobotReceiverFork' -vvv   # fork; needs RPC_<CHAIN> (Plasma skipped without RPC_PLASMA)
cd workflows/execution-chain-robot/offchain && bun test                                                 # CRE workflow (bun)
```

On every chain, the fork suite runs the deploy script, creates a payload on the live
`PayloadsController`, queues it as the `CrossChainController` delivers a passed proposal, and
checks the robot picks it only after its delay and executes it, agreeing with BGD's live
keeper where there is one. The Fast Gas feed is mocked, so results don't depend on live gas.
It also checks the gas cap, that expired payloads are skipped, and the harness's
`canPayloadBeExecuted` against `executePayload` at each timelock and expiry boundary.

## Deployment

`DeployExecutionChainRobotReceiver` picks the config from `block.chainid`: the chain's
`GovernanceV3<Chain>.PAYLOADS_CONTROLLER`, `EXECUTOR_LVL_1` / `GOVERNANCE_GUARDIAN` as owner
/ guardian, and the gas cap on Ethereum. It reverts on any other chain.

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
