# Voting Chain Robot

CRE robot automating the Aave Governance V3 voting machines: it starts a proposal's vote
once the storage roots it needs are registered and closes it (sending the result back to
Ethereum) once voting ends. Native CRE port of BGD Labs'
[`VotingChainRobotKeeper`](https://github.com/bgd-labs/aave-governance-v3-robots/blob/main/src/contracts/VotingChainRobotKeeper.sol)
and, on Ethereum, of its gas capped variant `GasCappedVotingChainRobotKeeper`, without
their storage roots requests (see [Storage roots](#storage-roots)). One receiver per voting
chain: Ethereum, Avalanche and Polygon.

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

`VotingChainRobotReceiver` implements [`IAaveCREReceiver`](../shared/src/IAaveCREReceiver.sol)
with the decision logic of BGD's keeper:

- `checkUpkeep(_) → (needed, ActionWithId[])` — read-only probe. Reads the proposals that
  received a vote configuration from the latest backwards, `PAGE_SIZE` (20) at a time,
  and reads the next page only while the current one had an action. For each proposal
  not disabled it picks one action:
  - `PerformCreateVote` — the vote isn't created and the roots of its L1 block hash are
    registered (the voting strategy's `hasRequiredRoots` plus the governance
    representatives root, the checks of `startProposalVote`);
  - `PerformCloseAndSendVote` — voting ended and the result wasn't sent yet.

  Stops at `MAX_ACTIONS` (5). Reports nothing while the gas price is above the cap.

- `onReport(metadata, ActionWithId[])` — performs the actions oldest proposal first, each
  only if it still applies and the proposal isn't disabled: `VotingMachine.startProposalVote`
  or `VotingMachine.closeAndSendVote`. A reverting action is caught so it can't block the
  rest of the batch. Reverts `NoActionCanBePerformed` if nothing was performed.

`onReport` is **permissionless**, like the keeper's `performUpkeep`: starting and closing
votes is permissionless on the voting machine, which checks the same conditions.

### Storage roots

A vote can only start once the `DataWarehouse` holds the Ethereum storage roots of the
proposal's snapshot block (AAVE, aAAVE, stkAAVE, Governance) and the stkAAVE exchange rate
slot. They are registered by the governance storage roots CRE workflow (part of
`automation-gov-1`): on `VotingActivated` it fetches the block header and the
`eth_getProof` proofs from an Ethereum RPC and writes them to each voting chain's
`DataWarehouse` (`processStorageRoot` / `processStorageSlot`, permissionless, proofs
verified on-chain), through `MailboxCRE`, without LINK.

BGD's keeper also requested them through BGD's `RootsConsumer` (a Chainlink node operator
paid in LINK fetching the proofs from BGD's API). That consumer isn't used, so this robot
has no roots action: a proposal whose roots are missing waits until the workflow registers
them, then gets `PerformCreateVote`. When the voting configuration is bridged after the
roots, the voting machine starts the vote itself.

### Gas price cap

With a `GAS_PRICE_ORACLE` (Ethereum only, Chainlink "Fast Gas / Gwei"), `checkUpkeep`
reports nothing while the feed answers above `getMaxGasPrice()`, as
`GasCappedVotingChainRobotKeeper` does. `onReport` doesn't check it. Without oracle there
is no cap.

### Differences with BGD's keeper

- No `PerformSubmitRoots` action, `RootsConsumer` or `retrySubmitRoots`: roots come from the
  storage roots workflow. `ProposalAction` is `PerformCreateVote` (0),
  `PerformCloseAndSendVote` (1); the keeper's values are one higher.
- More than `MAX_ACTIONS` due actions return the first five; the keeper's `checkUpkeep`
  reverts out of bounds on the sixth.
- `onReport` skips disabled proposals and catches a reverting action; the keeper only
  skips disabled proposals in `checkUpkeep` and reverts the whole batch.
- One contract for both keepers: the gas cap applies when deployed with a gas price oracle.
- `setMaxGasPrice` is owner or guardian, so tuning the cap doesn't need a governance vote.

### State and access control

- `_disabled[proposalId]` — proposals excluded from automation. A denylist: every new
  proposal is automated without any configuration.
- `disableAutomation(proposalId)` — owner or guardian. Reverts `ProposalStatusUnchanged`
  if already disabled.
- `enableAutomation(proposalId)` — owner-only. Reverts `ProposalStatusUnchanged` if not
  disabled.
- `setMaxGasPrice(maxGasPrice)` — owner or guardian. Reverts `MaxGasPriceUnchanged` for the
  current value and `GasPriceCapNotSupported` without oracle.
- The contract is `Rescuable`; the owner is the rescue guardian.

## Testing

```bash
# from repo root
forge test --match-path 'workflows/voting-chain-robot/tests/*.t.sol' --no-match-contract 'Fork' -vvv   # unit
forge test --match-contract 'VotingChainRobotReceiverFork' -vvv   # fork; needs RPC_MAINNET, RPC_AVALANCHE, RPC_POLYGON
cd workflows/voting-chain-robot/offchain && bun test               # CRE workflow (bun)
```

On each voting chain the fork suite runs the deploy script, bridges a vote configuration
for a new proposal with an unregistered block hash (as the L1 voting portal does) and
takes it through every action against the live contracts: nothing is due while its roots
are missing, the vote starts once they are registered (mocked, standing in for the storage
roots workflow) and is closed after the voting period. At each step the robot must pick
the same start / close actions as the live BGD keeper's `checkUpkeep`, ignoring the keeper's
roots requests. It also closes a real vote (proposal 531 on Avalanche, at a pinned block)
and checks the gas price cap on Ethereum.

`workflow.test.ts` runs `createReceiverHandler` against a mocked cre-sdk EVM client
(`EvmMock`) for each branch. Requires `bun` on PATH.

## Deployment

`VotingChainRobotReceiver` deploys stand-alone, one per voting chain.
`DeployVotingChainRobotReceiver` picks the config from `block.chainid`: the chain's
`GovernanceV3<Chain>.VOTING_MACHINE` (the data warehouse, voting strategy and governance
are read from it), and `EXECUTOR_LVL_1` / `GOVERNANCE_GUARDIAN` as owner / guardian.
Ethereum also gets the gas price oracle and the keeper's current cap, 150 gwei.

```bash
# from repo root, with ACCOUNT_NAME=<your-keystore-name> in .env
# env: Mainnet, Avalanche or Polygon
make deploy-voting-chain-robot env=Avalanche dry=true   # simulate
make deploy-voting-chain-robot env=Avalanche            # broadcast
```

### Post-deploy

1. Set each deployed address as the `receiver` of its chain in
   [`offchain/config.production.json`](offchain/config.production.json).
2. (Re)deploy the CRE workflow through the owner Safe — see
   [`offchain/README.md`](offchain/README.md). It can run alongside the BGD keepers:
   whichever acts first wins, the other finds nothing to do.
3. Stop driving the BGD keepers' `performUpkeep` (their Chainlink Automation upkeeps and
   the Voting Chain Robot entries of the `automation-gov-*` workflows), keeping the storage
   roots handler.

Post-deploy checks (substitute the deployed `<receiver>`):

```bash
cast call <receiver> "owner()(address)" --rpc-url <chain>
cast call <receiver> "guardian()(address)" --rpc-url <chain>
cast call <receiver> "VOTING_MACHINE()(address)" --rpc-url <chain>
cast call <receiver> "getMaxGasPrice()(uint256)" --rpc-url mainnet
```
