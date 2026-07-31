# Slashing

CRE robot that triggers [Umbrella](https://github.com/bgd-labs/aave-umbrella)
slashing on reserves that have a slashable deficit — covering bad debt from the
staked funds. Native CRE re-implementation of BGD Labs' `SlashingRobot`. Ethereum
only (Umbrella lives on mainnet).

## Layout

```
slashing/
├── src/
│   ├── SlashingReceiver.sol        # the robot — inherits IAaveCREReceiver, permissionless onReport
│   └── ISlashingReceiver.sol       # robot interface + minimal Umbrella interfaces
├── tests/
│   ├── SlashingReceiver.t.sol      # unit tests (vm.mockCall against Umbrella / stake tokens)
│   └── SlashingReceiver.fork.t.sol # fork tests against the live Ethereum Umbrella
├── scripts/
│   └── DeploySlashingReceiver.s.sol # stand-alone forge deploy
└── offchain/                       # CRE workflow — see offchain/README.md
```

## On-chain behavior

`SlashingReceiver` implements [`IAaveCREReceiver`](../shared/src/IAaveCREReceiver.sol):

- `checkUpkeep(_) → (needed, reserves[])` — read-only probe. Enumerates
  `UMBRELLA.getStkTokens()`, resolves each stake token's reserve, and flags a
  reserve when it has a slashable deficit (`isReserveSlashable`), the stake token
  is not paused, and it holds slashable funds (`getMaxSlashableAssets > 0`), up to
  `MAX_CHECK_SIZE` (10) per tick. `checkData` is unused — the Umbrella is an
  immutable of the contract.
- `onReport(metadata, reserves[])` — for each reserve still slashable (re-validated),
  calls `UMBRELLA.slash(reserve)` wrapped in `try/catch` so a stale report (front-run,
  racing keepers) skips instead of reverting the batch. Reverts `NoSlashesPerformed`
  if none were slashed.

`onReport` is intentionally **permissionless**: `metadata` and `msg.sender` are
ignored. Justification — `Umbrella.slash` is itself permissionless (anyone may
trigger it; it only acts when the reserve has a real deficit), so restricting who
delivers the report adds no security. No on-chain role is required.

### State

- `_disabled[reserve]` — excludes a reserve from automation. `checkUpkeep` and
  `onReport` both skip disabled reserves. Toggled via `setDisabled(reserve, disabled)`,
  owner or guardian.

## Testing

```bash
# from repo root
forge test --match-path 'workflows/slashing/tests/*.t.sol' --no-match-contract 'Fork' -vvv   # unit
RPC_MAINNET=... forge test --match-contract 'SlashingReceiverFork' -vvv                       # fork
cd workflows/slashing/offchain && bun test                                                    # CRE workflow (bun)
```

The fork suite forks Ethereum mainnet against the live
[`UmbrellaEthereum.UMBRELLA`](https://etherscan.io/address/0xD400fc38ED4732893174325693a63C30ee3881a8),
asserts the minimal local interfaces match the real deployed ABIs across the read
path, and exercises both the revert path (a non-slashable reserve →
`NoSlashesPerformed`) and the slash path (scans for a reserve with a live deficit;
skips if none is). It skips entirely when `RPC_MAINNET` is unset.

`workflow.test.ts` mocks the cre-sdk EVM client via `EvmMock` and drives
`createReceiverHandler` end-to-end for each branch. Generic helpers
(`encodeCheckUpkeepResult`, `CHECK_UPKEEP_SELECTOR`) live in
[`../shared/offchain/testing/mocks.ts`](../shared/offchain/testing/mocks.ts).
Requires `bun` on PATH.

## Deployment

`SlashingReceiver` deploys stand-alone. `DeploySlashingReceiver` wires
`UmbrellaEthereum.UMBRELLA` and uses `GovernanceV3Ethereum.EXECUTOR_LVL_1` /
`GOVERNANCE_GUARDIAN` as owner / guardian.

```bash
# from repo root, with ACCOUNT_NAME=<your-keystore-name> in .env
forge script workflows/slashing/scripts/DeploySlashingReceiver.s.sol \
  --rpc-url mainnet --account $ACCOUNT_NAME --broadcast --verify
```

### Post-deploy

1. Set the deployed address as `receiver` in
   [`offchain/config.production.json`](offchain/config.production.json).
2. (Re)deploy the CRE workflow through the owner Safe — see
   [`offchain/README.md`](offchain/README.md).

No on-chain role is required — `Umbrella.slash` is permissionless.

Post-deploy checks (substitute the deployed `<receiver>`):

```bash
cast call <receiver> "owner()(address)" --rpc-url mainnet
cast call <receiver> "guardian()(address)" --rpc-url mainnet
cast call <receiver> "UMBRELLA()(address)" --rpc-url mainnet
```
