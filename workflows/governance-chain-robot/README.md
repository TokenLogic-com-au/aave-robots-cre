# Governance Chain Robot

CRE robot that moves [Aave Governance V3](https://github.com/aave-dao/aave-governance-v3)
proposals forward: it activates voting after the cooldown, executes queued proposals and
cancels proposals whose creator lost the proposition power. Native CRE port of BGD's
[`GasCappedGovernanceChainRobotKeeper`](https://etherscan.io/address/0x1996c281235D99bB3c6B8d2afbEb8ac6c7A39C11#code).
Ethereum only (Governance V3 lives on mainnet).

## Layout

```
governance-chain-robot/
├── src/
│   ├── GovernanceChainRobotReceiver.sol        # the robot — GasCappedWorkflowsBase + IdDenylist, permissionless onReport
│   └── IGovernanceChainRobotReceiver.sol       # robot interface
├── tests/
│   ├── GovernanceChainRobotReceiver.t.sol      # unit tests against MockGovernance
│   ├── GovernanceChainRobotReceiver.fork.t.sol # fork tests against the live Governance and BGD keeper
│   ├── DeployGovernanceChainRobotReceiver.t.sol
│   └── helpers/                                # harness + MockGovernance
├── scripts/
│   └── DeployGovernanceChainRobotReceiver.s.sol
└── offchain/                                   # CRE workflow — see offchain/README.md
```

## On-chain behavior

`GovernanceChainRobotReceiver` extends
[`GasCappedWorkflowsBase`](../shared/src/GasCappedWorkflowsBase.sol) and
[`IdDenylist`](../shared/src/IdDenylist.sol), with proposal ids as the denylisted ids:

- `checkUpkeep(_) → (needed, ActionWithId[])` — returns nothing while automation is disabled
  or the [Fast Gas / Gwei](https://etherscan.io/address/0x169E633A2D1E6c10dD91238Ba11c4A708dfEF37C)
  feed is above `getMaxGasPrice()`. Otherwise it walks back from the latest proposal and,
  for each proposal not in a final state, picks the first that applies of:
  1. `PerformCancel` — the creator's proposition power is not above the access level's minimum;
  2. `PerformActivateVoting` — `Created` and past `coolDownBeforeVotingStart`;
  3. `PerformExecute` — `Queued` and past the Governance `COOLDOWN_PERIOD`.

  It stops once more than `MAX_SKIP` (20) consecutive proposals are final, i.e. after 21
  (a non-final proposal resets the count, disabled ones are ignored), or at `MAX_ACTIONS`
  (5). `checkData` is unused.

- `onReport(metadata, ActionWithId[])` — reverts `AutomationIsDisabled` while automation is
  disabled, otherwise performs the actions oldest proposal first,
  skipping disabled proposals and actions that no longer apply. A reverting Governance call
  emits `ActionFailed` instead of reverting the batch. Reverts `NoActionCanBePerformed` if
  nothing was performed.

`onReport` is **permissionless**: `metadata` and `msg.sender` are ignored. The Governance
calls are permissionless themselves and not payable (the CrossChainController pays the a.DI
fees), so the robot needs no role or funds.

### Differences with BGD's keeper

- `onReport` skips disabled proposals and emits `ActionFailed` for a reverting call, where
  BGD reverts the whole batch.
- A cancel is also flagged when the creator's power equals the minimum, when
  `cancelProposal` already opens to anyone (BGD uses `<`).
- Explicit `disableAutomation` / `enableAutomation` instead of a toggle; setters revert when
  nothing changes.
- Same as BGD: a `Created` proposal whose voting portal is no longer approved keeps being
  flagged for activation (and fails) until it is disabled or expires.

### Access control

From the shared base:

- `disableAutomation()` (owner or guardian) / `enableAutomation()` (owner) — the whole robot.
- `disableId(id)` (owner or guardian) / `enableId(id)` (owner) — a single
  proposal; new proposals are automated by default. Revert `IdStatusUnchanged` when
  the status doesn't change and emit `IdDisabled(id, disabled)`.
- `setMaxGasPrice(maxGasPrice)` — owner or guardian, so the cap can be tuned without a vote.
  `setMaxGasPrice(0)` is the guardian's emergency pause: the constructor rejects 0 to catch
  deploy mistakes, the setter allows it on purpose. The constructor also requires a gas price
  feed: on Ethereum the robot is always capped.
- Owner `EXECUTOR_LVL_1`, guardian `GOVERNANCE_GUARDIAN`. `Rescuable`, with the owner as
  rescue guardian.

## Testing

```bash
# from repo root
forge test --match-path 'workflows/governance-chain-robot/tests/*.t.sol' --no-match-contract 'Fork' -vvv  # unit
forge test --match-contract 'GovernanceChainRobotReceiverFork' -vvv                                       # fork; needs RPC_MAINNET
cd workflows/governance-chain-robot/offchain && bun test                                                   # CRE workflow (bun)
```

The fork suite pins block `26207306` (proposal 531 `Active`, 532 `Created`) and checks every
`checkUpkeep` against BGD's live keeper. It activates 532 after its cooldown, queues and
executes 531, cancels both once their creators' power is mocked to zero, and covers the gas
price cap, a disabled proposal and a stale report. The access control, global switch, gas cap
and per-id denylist are tested once in [`shared/tests`](../shared/tests).

## Deployment

`DeployGovernanceChainRobotReceiver` wires `GovernanceV3Ethereum.GOVERNANCE`,
`ChainlinkEthereum.Fast_Gas__Gwei` and `MAX_GAS_PRICE` (150 gwei, BGD's value), with the
owner / guardian from `GovernanceOwners` (`EXECUTOR_LVL_1` / `GOVERNANCE_GUARDIAN`). It
reverts on any other chain.

```bash
# from repo root, with ACCOUNT_NAME=<your-keystore-name> in .env
make deploy-governance-chain-robot env=Mainnet dry=true   # simulate
make deploy-governance-chain-robot env=Mainnet            # broadcast
```

### Post-deploy

1. Set the deployed address as `receiver` in
   [`offchain/config.production.json`](offchain/config.production.json).
2. (Re)deploy the CRE workflow through the owner Safe — see
   [`offchain/README.md`](offchain/README.md).
3. Remove BGD's keeper from the `MailboxCRE` workflow.

```bash
cast call <receiver> "owner()(address)" --rpc-url mainnet
cast call <receiver> "guardian()(address)" --rpc-url mainnet
cast call <receiver> "getMaxGasPrice()(uint256)" --rpc-url mainnet
cast call <receiver> "checkUpkeep(bytes)(bool,bytes)" 0x --rpc-url mainnet
```
