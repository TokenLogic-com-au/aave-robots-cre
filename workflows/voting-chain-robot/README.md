# Voting Chain Robot

CRE robot automating the Aave Governance V3 voting machines: it starts a proposal's vote
once its storage roots are registered and closes it (sending the result to Ethereum) once
voting ends. Native CRE port of BGD's
[`VotingChainRobotKeeper`](https://github.com/bgd-labs/aave-governance-v3-robots/blob/main/src/contracts/VotingChainRobotKeeper.sol)
and its gas capped variant. One receiver per voting chain: Ethereum, Avalanche and Polygon.

## Layout

```
voting-chain-robot/
├── src/
│   ├── VotingChainRobotReceiver.sol        # the robot — inherits IAaveCREReceiver, permissionless onReport
│   └── IVotingChainRobotReceiver.sol       # robot interface
├── tests/
│   ├── VotingChainRobotReceiver.t.sol      # unit tests (vm.mockCall against the voting machine & co.)
│   ├── VotingChainRobotReceiver.fork.t.sol # fork tests on every voting chain, against the live keepers
│   └── helpers/
│       └── VotingChainRobotReceiverHarness.sol
├── scripts/
│   └── DeployVotingChainRobotReceiver.s.sol # stand-alone forge deploy, per chain
└── offchain/                               # CRE workflow — see offchain/README.md
```

## On-chain behavior

`VotingChainRobotReceiver` implements [`IAaveCREReceiver`](../shared/src/IAaveCREReceiver.sol):

- `checkUpkeep(_) → (needed, ActionWithId[])` — reads the proposals with a vote
  configuration from the latest backwards, `PAGE_SIZE` (20) at a time, reading the next
  page only while the current one had an action, up to `MAX_ACTIONS` (5). Per proposal not
  disabled: `PerformCreateVote` when the vote isn't created and the roots of its L1 block
  hash are registered (`hasRequiredRoots` plus the governance representatives root, as
  `startProposalVote` checks), `PerformCloseAndSendVote` when voting ended and the result
  wasn't sent. Nothing while the gas price is above the cap.
- `onReport(metadata, ActionWithId[])` — calls `startProposalVote` / `closeAndSendVote`,
  oldest proposal first, for each action still due on a proposal not disabled. A reverting
  action is caught; reverts `NoActionCanBePerformed` if nothing ran.

`onReport` is **permissionless**: both voting machine calls are permissionless and check
the same conditions.

With a `GAS_PRICE_ORACLE` (Ethereum only, Chainlink "Fast Gas / Gwei") `checkUpkeep`
reports nothing while the feed answers above `getMaxGasPrice()`; `onReport` doesn't check it.

### Storage roots

The roots are registered on each voting chain's `DataWarehouse` by the governance storage
roots CRE workflow (`automation-gov-1`): on `VotingActivated` it fetches the Ethereum proofs
and submits them through `MailboxCRE`. BGD's keeper also requested them from its
LINK-funded `RootsConsumer`, which isn't used, so this robot has no roots action: a
proposal whose roots are missing waits for them.

### Differences with BGD's keeper

- No roots requests (`RootsConsumer`, `retrySubmitRoots`). `ProposalAction` values are one
  lower than the keeper's.
- More than 5 due actions return the first five; the keeper's `checkUpkeep` reverts.
- Paging stops at the first page without an action; the keeper kept paging on pages with
  only roots requests, which don't exist here.
- `onReport` skips disabled proposals and catches reverting actions instead of reverting
  the batch.
- One contract for both keepers; `setMaxGasPrice` is owner or guardian.
- As with BGD's keeper, a deprecated Fast Gas feed makes `checkUpkeep` revert until the
  receiver is redeployed.

### State and access control

- `disableAutomation(id)` — owner or guardian; `enableAutomation(id)` — owner. Both revert
  `AutomationStatusUnchanged` when the status doesn't change and emit
  `AutomationDisabled(id, disabled)`. A denylist: new proposals need no configuration.
- `setMaxGasPrice(maxGasPrice)` — owner or guardian. Reverts `MaxGasPriceUnchanged` for the
  current value and `GasPriceCapNotSupported` without oracle. The constructor requires a
  non-zero cap with an oracle and none without.
- The contract is `Rescuable`; the owner is the rescue guardian.

## Testing

```bash
# from repo root
forge test --match-path 'workflows/voting-chain-robot/tests/*.t.sol' --no-match-contract 'Fork' -vvv   # unit
forge test --match-contract 'VotingChainRobotReceiverFork' -vvv   # fork; needs RPC_MAINNET, RPC_AVALANCHE, RPC_POLYGON
cd workflows/voting-chain-robot/offchain && bun test               # CRE workflow (bun)
```

On each chain, at a pinned block, the fork suite runs the deploy script, bridges a vote
configuration for a new proposal and checks nothing is due until its roots are registered
(mocked), then that the robot starts the vote and closes it after the voting period,
picking the same start / close actions as the live keeper. It also closes Avalanche
proposal 531 and checks the Ethereum gas cap.

## Deployment

`DeployVotingChainRobotReceiver` picks the config from `block.chainid`: the chain's
`GovernanceV3<Chain>.VOTING_MACHINE` (data warehouse, voting strategy and governance are
read from it) and `EXECUTOR_LVL_1` / `GOVERNANCE_GUARDIAN` as owner / guardian. Ethereum
also gets the Fast Gas feed and the keeper's cap, 150 gwei.

```bash
# from repo root, with ACCOUNT_NAME=<your-keystore-name> in .env; env: Mainnet, Avalanche or Polygon
make deploy-voting-chain-robot env=Avalanche dry=true   # simulate
make deploy-voting-chain-robot env=Avalanche            # broadcast
```

### Post-deploy

1. Set each deployed address as the `receiver` of its chain in
   [`offchain/config.production.json`](offchain/config.production.json).
2. (Re)deploy the CRE workflow through the owner Safe — see
   [`offchain/README.md`](offchain/README.md).
3. Stop driving the BGD keepers (their Chainlink Automation upkeeps and the Voting Chain
   Robot entries of `automation-gov-*`), keeping the storage roots handler.

```bash
cast call <receiver> "owner()(address)" --rpc-url <chain>
cast call <receiver> "VOTING_MACHINE()(address)" --rpc-url <chain>
cast call <receiver> "getMaxGasPrice()(uint256)" --rpc-url mainnet
```
