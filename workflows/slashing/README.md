# Slashing

CRE robot that triggers [Umbrella](https://github.com/bgd-labs/aave-umbrella) slashing
on reserves with a slashable deficit, covering the bad debt from the staked funds.
Native CRE port of BGD Labs'
[`SlashingRobot`](https://github.com/bgd-labs/aave-umbrella/blob/main/src/contracts/automation/SlashingRobot.sol).
Ethereum only (Umbrella is deployed on mainnet).

## Layout

```
slashing/
├── src/
│   ├── SlashingReceiver.sol        # the robot — inherits IAaveCREReceiver, permissionless onReport
│   └── ISlashingReceiver.sol       # robot interface + minimal stake token interface
├── tests/
│   ├── SlashingReceiver.t.sol      # unit tests (vm.mockCall against Umbrella / stake tokens)
│   ├── SlashingReceiver.fork.t.sol # fork tests against the live Ethereum Umbrella
│   └── helpers/
│       └── SlashingReceiverHarness.sol
├── scripts/
│   └── DeploySlashingReceiver.s.sol # stand-alone forge deploy
└── offchain/                       # CRE workflow — see offchain/README.md
```

## On-chain behavior

`SlashingReceiver` implements [`IAaveCREReceiver`](../shared/src/IAaveCREReceiver.sol):

- `checkUpkeep(_) → (needed, reserves[])` — read-only probe. Enumerates
  `UMBRELLA.getStkTokens()` and flags each stake token's reserve when it has a
  slashable deficit (`isReserveSlashable`), the stake token is not paused and it
  holds slashable funds (`getMaxSlashableAssets > 0`), up to `MAX_CHECK_SIZE` (10)
  per tick. `checkData` is unused: the Umbrella is an immutable of the contract.
- `onReport(metadata, reserves[])` — calls `UMBRELLA.slash(reserve)` for each reserve
  that is still slashable and not disabled. A reverting `slash` is caught so it can't
  block the rest of the batch. Reverts `NoSlashesPerformed` if nothing was slashed.

`onReport` is **permissionless**: `metadata` and `msg.sender` are ignored. It can only
call `slash` on the Umbrella set at deployment, which is permissionless itself and
only acts on a real deficit. No on-chain role is required.

Unlike BGD's robot, `checkUpkeep` doesn't shuffle the stake tokens, since the shuffle
relies on `blockhash` and CRE nodes may read different blocks. With more than
`MAX_CHECK_SIZE` slashable reserves, the first ones in `getStkTokens()` order go
first; a reserve whose `slash` keeps reverting should be disabled by the guardian so
it doesn't hold a slot.

### State and access control

- `_disabled[reserve]` — reserves excluded from automation. Reserves are enabled by
  default, so new Umbrella reserves are covered without any action.
- `disableReserve(reserve)` — owner or guardian (emergency off-switch). Reverts
  `ReserveStatusUnchanged` if already disabled.
- `enableReserve(reserve)` — owner-only. Reverts `ReserveStatusUnchanged` if not
  disabled.
- Both emit `ReserveDisabled(reserve, disabled)`.
- The contract is `Rescuable`; the owner is the rescue guardian.

## Testing

```bash
# from repo root
forge test --match-path 'workflows/slashing/tests/*.t.sol' --no-match-contract 'Fork' -vvv   # unit
forge test --match-contract 'SlashingReceiverFork' -vvv                                      # fork; needs RPC_MAINNET
cd workflows/slashing/offchain && bun test                                                    # CRE workflow (bun)
```

The fork suite runs against the live
[`UmbrellaEthereum.UMBRELLA`](https://etherscan.io/address/0xD400fc38ED4732893174325693a63C30ee3881a8).
Besides the read path and the revert path, it mocks the Pool's reported deficit for
one reserve above Umbrella's offset and checks the robot slashes it on the real
Umbrella, for the amount the pending deficit grows by.

`workflow.test.ts` runs `createReceiverHandler` against a mocked cre-sdk EVM client
(`EvmMock`) for each branch, for both the cron and the `DeficitCreated` log trigger
(see [`offchain/README.md`](offchain/README.md)). Requires `bun` on PATH.

## Deployment

`SlashingReceiver` deploys stand-alone. `DeploySlashingReceiver` wires
`UmbrellaEthereum.UMBRELLA` and uses `GovernanceV3Ethereum.EXECUTOR_LVL_1` /
`GOVERNANCE_GUARDIAN` as owner / guardian.

```bash
# from repo root, with ACCOUNT_NAME=<your-keystore-name> in .env
make deploy-slashing env=Mainnet dry=true   # simulate
make deploy-slashing env=Mainnet            # broadcast
```

### Post-deploy

1. Set the deployed address as `receiver` in
   [`offchain/config.production.json`](offchain/config.production.json).
2. (Re)deploy the CRE workflow through the owner Safe — see
   [`offchain/README.md`](offchain/README.md).

Post-deploy checks (substitute the deployed `<receiver>`):

```bash
cast call <receiver> "owner()(address)" --rpc-url mainnet
cast call <receiver> "guardian()(address)" --rpc-url mainnet
cast call <receiver> "UMBRELLA()(address)" --rpc-url mainnet
```
