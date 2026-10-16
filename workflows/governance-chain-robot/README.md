# Governance Chain Robot

CRE robot that moves [Aave Governance V3](https://github.com/aave-dao/aave-governance-v3)
proposals forward on the governance chain: it activates voting once a proposal's cooldown
has passed, executes queued proposals and cancels proposals whose creator lost the
proposition power. Native CRE port of BGD Labs'
[`GasCappedGovernanceChainRobotKeeper`](https://etherscan.io/address/0x1996c281235D99bB3c6B8d2afbEb8ac6c7A39C11#code)
([source](https://github.com/bgd-labs/aave-governance-v3-robots)), which runs today through
Chainlink Automation / `MailboxCRE`. Ethereum only (Governance V3 lives on mainnet).

## Layout

```
governance-chain-robot/
├── src/
│   ├── GovernanceChainRobotReceiver.sol      # the robot — inherits IAaveCREReceiver, permissionless onReport
│   └── IGovernanceChainRobotReceiver.sol     # robot interface, actions, events and errors
├── tests/
│   ├── GovernanceChainRobotReceiver.t.sol      # unit tests against MockGovernance
│   ├── GovernanceChainRobotReceiver.fork.t.sol # fork tests against the live Governance and BGD keeper
│   ├── DeployGovernanceChainRobotReceiver.t.sol
│   └── helpers/
│       ├── GovernanceChainRobotReceiverHarness.sol
│       └── MockGovernance.sol
├── scripts/
│   └── DeployGovernanceChainRobotReceiver.s.sol # stand-alone forge deploy
└── offchain/                                    # CRE workflow — see offchain/README.md
```

## On-chain behavior

`GovernanceChainRobotReceiver` implements [`IAaveCREReceiver`](../shared/src/IAaveCREReceiver.sol):

- `checkUpkeep(_) → (needed, ActionWithId[])` — read-only probe, same decision as BGD's
  keeper. Returns nothing while the
  [Fast Gas / Gwei](https://etherscan.io/address/0x169E633A2D1E6c10dD91238Ba11c4A708dfEF37C)
  feed is above `getMaxGasPrice()`. Otherwise it walks back from the latest proposal and,
  per proposal not in a final state (Executed, Failed, Cancelled, Expired), picks the first
  that applies of:
  1. `PerformCancel` — not executed yet and the creator's proposition power is not above
     the access level's `minPropositionPower`;
  2. `PerformActivateVoting` — `Created` and past the access level's
     `coolDownBeforeVotingStart`;
  3. `PerformExecute` — `Queued` and past the Governance `COOLDOWN_PERIOD`.

  It stops after `MAX_SKIP` (20) consecutive proposals in a final state (a non-final one
  resets the count; disabled ones neither count nor reset it) or once `MAX_ACTIONS` (5)
  are found. `performData` lists them newest first. `checkData` is unused.

- `onReport(metadata, ActionWithId[])` — performs the actions oldest proposal first,
  skipping disabled proposals and actions that no longer apply, through
  `activateVoting` / `executeProposal` / `cancelProposal`. A reverting Governance call is
  caught so it can't block the rest of the batch. Reverts `NoActionCanBePerformed` if
  nothing was performed.

`onReport` is **permissionless**: `metadata` and `msg.sender` are ignored. The three
Governance calls are permissionless themselves (`cancelProposal` once the creator lost the
proposition power) and only act when the Governance's own checks pass. None of them is
payable: the a.DI bridge fees for voting activation and execution are paid by the
CrossChainController, so the robot holds no funds and needs no on-chain role.

### Differences with BGD's keeper

- `onReport` skips disabled proposals (BGD's `performUpkeep` only filters them in
  `checkUpkeep`), and catches a reverting Governance call instead of reverting the batch.
- A cancel is flagged when the creator's power is equal to the minimum too, which is when
  `Governance.cancelProposal` opens to anyone (BGD uses a strict `<`).
- Disabling is explicit (`disableAutomation` / `enableAutomation`, reverting when the
  status doesn't change) instead of `toggleDisableAutomationById`, and the max gas price
  setter reverts when the value doesn't change.
- Owner is `EXECUTOR_LVL_1` and guardian `GOVERNANCE_GUARDIAN` (BGD's keeper is owned by
  the robot guardian Safe).

As in BGD's keeper, the gas price cap only gates `checkUpkeep`.

### State and access control

- `_disabled[id]` — proposals excluded from automation. New proposals are covered without
  any action.
- `disableAutomation(id)` — owner or guardian (emergency off-switch). Reverts
  `ProposalStatusUnchanged` if already disabled.
- `enableAutomation(id)` — owner-only. Reverts `ProposalStatusUnchanged` if not disabled.
- Both emit `ProposalAutomationDisabled(id, disabled)`.
- `setMaxGasPrice(maxGasPrice)` — owner or guardian, so the cap can be tuned without a
  governance vote. Reverts `MaxGasPriceUnchanged` if unchanged; emits `MaxGasPriceSet`.
- The contract is `Rescuable`; the owner is the rescue guardian.

## Testing

```bash
# from repo root
forge test --match-path 'workflows/governance-chain-robot/tests/*.t.sol' --no-match-contract 'Fork' -vvv  # unit
forge test --match-contract 'GovernanceChainRobotReceiverFork' -vvv                                       # fork; needs RPC_MAINNET
cd workflows/governance-chain-robot/offchain && bun test                                                   # CRE workflow (bun)
```

The fork suite pins block `26207306`, where proposal 531 is `Active` and 532 is `Created`
within its cooldown, and checks every `checkUpkeep` returns the same `performData` as BGD's
live keeper. From there it warps past 532's cooldown and activates its voting; ends 531's
vote, queues it as its voting portal and executes it (activating 532 in the same report);
mocks both creators' proposition power to zero and cancels both; and checks the gas price
cap, a disabled proposal and the stale-report revert.

## Deployment

`GovernanceChainRobotReceiver` deploys stand-alone. `DeployGovernanceChainRobotReceiver`
wires `GovernanceV3Ethereum.GOVERNANCE`, `ChainlinkEthereum.Fast_Gas__Gwei` and a 150 gwei
max gas price (the BGD keeper's), and uses `GovernanceV3Ethereum.EXECUTOR_LVL_1` /
`GOVERNANCE_GUARDIAN` as owner / guardian. It reverts on any chain but Ethereum.

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
3. Remove the BGD keeper from the `MailboxCRE`-forwarded workflow (and its Chainlink
   Automation upkeep, if any). Running both is harmless (a second report finds nothing to
   do and fails `estimateGas`) but wastes reads.

Post-deploy checks (substitute the deployed `<receiver>`):

```bash
cast call <receiver> "owner()(address)" --rpc-url mainnet
cast call <receiver> "guardian()(address)" --rpc-url mainnet
cast call <receiver> "GOVERNANCE()(address)" --rpc-url mainnet
cast call <receiver> "getMaxGasPrice()(uint256)" --rpc-url mainnet
cast call <receiver> "checkUpkeep(bytes)(bool,bytes)" 0x --rpc-url mainnet
```
