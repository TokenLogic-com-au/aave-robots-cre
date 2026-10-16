# Voting Chain Robot

CRE robot automating the Aave Governance V3 voting machines: it requests the storage
roots a proposal's vote needs, starts the vote once they are registered and closes it
(sending the result back to Ethereum) once voting ends. Native CRE port of BGD Labs'
[`VotingChainRobotKeeper`](https://github.com/bgd-labs/aave-governance-v3-robots/blob/main/src/contracts/VotingChainRobotKeeper.sol)
and, on Ethereum, of its gas capped variant `GasCappedVotingChainRobotKeeper`. One
receiver per voting chain: Ethereum, Avalanche and Polygon.

## Layout

```
voting-chain-robot/
├── src/
│   ├── VotingChainRobotReceiver.sol        # the robot — inherits IAaveCREReceiver, permissionless onReport
│   └── IVotingChainRobotReceiver.sol       # robot interface + minimal IRootsConsumer
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
  - `PerformSubmitRoots` — the vote isn't created, the roots of its L1 block hash are
    missing, the robot didn't request them yet and is the `RootsConsumer`'s robot keeper;
  - `PerformCreateVote` — the vote isn't created and the roots are registered (the voting
    strategy's `hasRequiredRoots` plus the governance representatives root, the checks of
    `startProposalVote`);
  - `PerformCloseAndSendVote` — voting ended and the result wasn't sent yet.

  Stops at `MAX_ACTIONS` (5). Reports nothing while the gas price is above the cap.
  `performData` has the same encoding as the keeper's.

- `onReport(metadata, ActionWithId[])` — performs the actions oldest proposal first, each
  only if it still applies and the proposal isn't disabled: `RootsConsumer.requestSubmitRoots`,
  `VotingMachine.startProposalVote` or `VotingMachine.closeAndSendVote`. A reverting action
  is caught so it can't block the rest of the batch. Reverts `NoActionCanBePerformed` if
  nothing was performed.

`onReport` is **permissionless**, like the keeper's `performUpkeep`: starting and closing
votes is permissionless on the voting machine, and the roots of a block hash are requested
at most once (until `retrySubmitRoots`), only while a proposal waits for them, so nobody
can make the robot spend the `RootsConsumer`'s LINK otherwise.

### Storage roots

A vote can only start once the `DataWarehouse` holds the Ethereum storage roots of the
proposal's snapshot block (AAVE, aAAVE, stkAAVE, Governance) and the stkAAVE exchange rate
slot. Registering them needs off-chain data: the block header and `eth_getProof` proofs of
those accounts on Ethereum. Like BGD's keeper, the robot doesn't build them itself: it calls
BGD's [`RootsConsumer`](https://github.com/bgd-labs/aave-governance-v3-robots/blob/main/src/contracts/RootsConsumer.sol)
(one per voting chain), which pays a Chainlink node operator in LINK to fetch them from
BGD's API (`aave-governance-v3-robot.vercel.app/api/roots`) and registers them through
`processStorageRoot` / `processStorageSlot` on its callback. Only the consumer's robot
keeper may request, so the robot only reports `PerformSubmitRoots` once governance points
the consumer to it.

`processStorageRoot` and `processStorageSlot` are permissionless and verify the proofs
against the block hash, so a CRE workflow can register the roots without the consumer:
on `VotingActivated` (Ethereum `GovernanceCore`), fetch the header (`eth_getBlockByHash`)
and the proofs (`eth_getProof` at the snapshot block) from an Ethereum RPC through CRE's
HTTP capability (the EVM capability has no `eth_getProof`), RLP-encode them and write them
to the voting chain's `DataWarehouse`. This is what BGD's `cre/gov-storage-roots` workflow
does; with it, this robot only starts and closes votes.

### Gas price cap

With a `GAS_PRICE_ORACLE` (Ethereum only, Chainlink "Fast Gas / Gwei"), `checkUpkeep`
reports nothing while the feed answers above `getMaxGasPrice()`, as
`GasCappedVotingChainRobotKeeper` does. `onReport` doesn't check it. Without oracle there
is no cap.

### Differences with BGD's keeper

- More than `MAX_ACTIONS` due actions return the first five; the keeper's `checkUpkeep`
  reverts out of bounds on the sixth.
- `onReport` skips disabled proposals and catches a reverting action; the keeper only
  skips disabled proposals in `checkUpkeep` and reverts the whole batch.
- `PerformSubmitRoots` is only reported while the robot is the `RootsConsumer`'s robot
  keeper, so an unset keeper doesn't block the batch's other actions.
- One contract for both keepers: the gas cap applies when deployed with a gas price oracle.
- `retrySubmitRoots` is owner or guardian (the keeper's owner was BGD's robot owner; here
  the owner is the governance executor).

### State and access control

- `_disabled[proposalId]` — proposals excluded from automation. A denylist: every new
  proposal is automated without any configuration.
- `disableAutomation(proposalId)` — owner or guardian. Reverts `ProposalStatusUnchanged`
  if already disabled.
- `enableAutomation(proposalId)` — owner-only. Reverts `ProposalStatusUnchanged` if not
  disabled.
- `retrySubmitRoots(proposalId)` — owner or guardian, clears the roots request of the
  proposal's block hash, e.g. after the node operator failed to fulfill it. Reverts
  `RootsNotRequested` if there is none.
- `setMaxGasPrice(maxGasPrice)` — owner-only. Reverts `MaxGasPriceUnchanged` for the
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
for a new proposal with an unregistered block hash (as the L1 voting portal does), and
takes it through every action against the live contracts: the robot requests the roots
once governance sets it as the `RootsConsumer`'s robot keeper (the consumer sends the
operator request), starts the vote once the roots are registered (mocked, standing in for
the operator's callback) and closes it after the voting period. At each step `checkUpkeep`
must return the same `performData` as the live BGD keeper. It also closes a real vote
(proposal 531 on Avalanche, at a pinned block) and checks the gas price cap on Ethereum.

`workflow.test.ts` runs `createReceiverHandler` against a mocked cre-sdk EVM client
(`EvmMock`) for each branch. Requires `bun` on PATH.

## Deployment

`VotingChainRobotReceiver` deploys stand-alone, one per voting chain.
`DeployVotingChainRobotReceiver` picks the config from `block.chainid`: the chain's
`GovernanceV3<Chain>.VOTING_MACHINE` (the data warehouse, voting strategy and governance
are read from it), BGD's `RootsConsumer` of the chain, and `EXECUTOR_LVL_1` /
`GOVERNANCE_GUARDIAN` as owner / guardian. Ethereum also gets the gas price oracle and
the keeper's current cap, 150 gwei.

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
   [`offchain/README.md`](offchain/README.md). From then on it starts and closes votes
   alongside the live keepers (whichever acts first wins, the other finds nothing to do).
3. Governance (the `RootsConsumer` owner, `EXECUTOR_LVL_1`) or the consumer's guardian
   calls `setRobotKeeper(<receiver>)` on each chain's `RootsConsumer`; until then the
   robot doesn't request roots. This moves root requests away from BGD's keeper.
4. Stop whatever drives the BGD keepers' `performUpkeep` (their Chainlink Automation
   upkeeps).

The `RootsConsumer`s must hold enough LINK for their fee.

Post-deploy checks (substitute the deployed `<receiver>`):

```bash
cast call <receiver> "owner()(address)" --rpc-url <chain>
cast call <receiver> "VOTING_MACHINE()(address)" --rpc-url <chain>
cast call <receiver> "ROOTS_CONSUMER()(address)" --rpc-url <chain>
cast call <receiver> "getMaxGasPrice()(uint256)" --rpc-url mainnet
cast call <roots-consumer> "getRobotKeeper()(address)" --rpc-url <chain>
```
