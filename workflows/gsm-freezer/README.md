# GSM Freezer

CRE robot that freezes (and unfreezes) [GSM](https://github.com/aave/gho-core)
swaps when the underlying asset's oracle price leaves a configured band — the
depeg protection for GHO's Gho Stability Modules. Native CRE re-implementation of
the GSM `ChainlinkOracleSwapFreezer`. One receiver per GSM (Ethereum: USDC + USDT).

## Layout

```
gsm-freezer/
├── src/
│   ├── GsmFreezerReceiver.sol        # the robot — inherits IAaveCREReceiver, permissionless onReport
│   └── IGsmFreezerReceiver.sol       # robot interface + minimal IGsm / oracle interfaces
├── tests/
│   ├── GsmFreezerReceiver.t.sol      # unit tests (vm.mockCall against the GSM / oracle)
│   └── GsmFreezerReceiver.fork.t.sol # fork tests that freeze the live Ethereum GSM
├── scripts/
│   └── DeployGsmFreezerReceiver.s.sol # stand-alone forge deploy (USDC + USDT)
└── offchain/                         # CRE workflow — see offchain/README.md
```

## On-chain behavior

`GsmFreezerReceiver` implements [`IAaveCREReceiver`](../shared/src/IAaveCREReceiver.sol):

- `checkUpkeep(_) → (needed, action)` — read-only probe. Derives an `Action`
  (`FREEZE` / `UNFREEZE` / `NONE`) from live state: the robot must hold
  `SWAP_FREEZER_ROLE`, the GSM must not be seized, and the Aave V3 oracle price of
  the underlying (8-decimal USD) must cross a bound. **FREEZE** when not frozen and
  `price ≤ freezeLowerBound || price ≥ freezeUpperBound`; **UNFREEZE** when frozen,
  `allowUnfreeze`, and `unfreezeLowerBound ≤ price ≤ unfreezeUpperBound`. `checkData`
  is unused — the GSM and bounds are immutables of the contract.
- `onReport(metadata, _)` — **re-derives the action on-chain** (the report payload
  is ignored) and calls `GSM.setSwapFreeze(true|false)`, or reverts `NoActionPossible`
  if no action currently applies. Re-deriving from live state means a stale/forged
  report cannot force a freeze/unfreeze that current prices don't warrant.

The bounds mirror the audited on-chain freezers: freeze outside `[0.99, 1.01]`,
unfreeze back inside `[0.995, 1.005]` (hysteresis).

`onReport` is intentionally **permissionless** (like the legacy freezer and
`FeeSharesMinter`): `metadata` / `msg.sender` are ignored, so a caller can only
trigger the action live prices already warrant. Note the unfreeze side is public
too — a manual/emergency freeze made while the price is in the unfreeze band should
be paired with `setDisabled(true)` (or the GSM deployed with `allowUnfreeze == false`)
so the robot doesn't unfreeze it.

### State

- `_disabled` — excludes the robot from automation. `checkUpkeep` and `onReport`
  both stand down while set. Toggled via `setDisabled(disabled)`, owner or guardian.

## Testing

```bash
# from repo root
forge test --match-path 'workflows/gsm-freezer/tests/*.t.sol' --no-match-contract 'Fork' -vvv   # unit
RPC_MAINNET=... forge test --match-contract 'GsmFreezerReceiverFork' -vvv                        # fork
cd workflows/gsm-freezer/offchain && bun test                                                    # CRE workflow (bun)
```

The fork suite forks Ethereum mainnet against the live
[`GhoEthereum.GSM_USDC`](https://etherscan.io/address/0x3A3868898305f04beC7FEa77BecFf04C13444112),
locks the read-path ABI unconditionally, and — by granting `SWAP_FREEZER_ROLE` (as
governance would) and mocking a depeg — drives an unpermissioned `onReport` that
**freezes and unfreezes the real GSM**. It requires `RPC_MAINNET` (the fork `setUp`
reverts if unset).

`workflow.test.ts` mocks the cre-sdk EVM client via `EvmMock` and drives
`createReceiverHandler` end-to-end for each branch. Requires `bun` on PATH.

## Deployment

`GsmFreezerReceiver` deploys stand-alone, one instance per GSM.
`DeployGsmFreezerReceiver` deploys the Ethereum USDC + USDT freezers from
`aave-address-book` constants, with `GovernanceV3Ethereum.EXECUTOR_LVL_1` /
`GOVERNANCE_GUARDIAN` as owner / guardian.

```bash
# from repo root, with ACCOUNT_NAME=<your-keystore-name> in .env
make deploy-gsm-freezer env=Mainnet dry=1   # simulate
make deploy-gsm-freezer env=Mainnet         # broadcast + verify
```

### Post-deploy

1. **Governance grants `SWAP_FREEZER_ROLE`** to each deployed receiver on its GSM —
   unlike the other native robots, this action is role-gated. Until the role is
   granted the robot reads `hasRole == false` and stands down (`checkUpkeep` returns
   `false`), so it is safe to deploy and register the workflow first.
2. Set each deployed address as a `receiver` in
   [`offchain/config.production.json`](offchain/config.production.json) (USDC + USDT).
3. (Re)deploy the CRE workflow through the owner Safe — see
   [`offchain/README.md`](offchain/README.md).

Post-deploy checks (substitute the deployed `<receiver>`):

```bash
cast call <receiver> "owner()(address)" --rpc-url mainnet
cast call <receiver> "GSM()(address)" --rpc-url mainnet
cast call <gsm> "hasRole(bytes32,address)(bool)" \
  0x6dac4cc0544e34aa1a4ed2862f6de78290e3f18f00fe77179ee8ef34de9dfa24 <receiver> --rpc-url mainnet
```
