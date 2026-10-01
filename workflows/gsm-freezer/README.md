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

`GsmFreezerReceiver` implements [`IAaveCREReceiver`](../shared/src/IAaveCREReceiver.sol),
with the same decision logic as the GSM's audited `OracleSwapFreezer`:

- `checkUpkeep(_) → (needed, action)` — read-only probe. Returns `FREEZE` when the GSM
  is not frozen and the Aave V3 oracle price of the underlying (8-decimal USD) is
  `≤ freezeLowerBound` or `≥ freezeUpperBound`, and `UNFREEZE` when it is frozen,
  `allowUnfreeze` is set and the price is back within `[unfreezeLowerBound,
unfreezeUpperBound]`. Nothing while the robot lacks `SWAP_FREEZER_ROLE`, the GSM is
  seized, the price is 0 or automation is disabled.
- `onReport(metadata, _)` — ignores the report, derives the same action from live state
  and calls `GSM.setSwapFreeze`. Reverts `NoActionPossible` if nothing applies.

Bounds follow `OracleSwapFreezer`: inclusive, unfreeze band nested in the freeze band,
and both unfreeze bounds 0 when `allowUnfreeze` is false. The deploy script uses the
same values as the live freezers: freeze outside `[0.99, 1.01]`, unfreeze inside
`[0.995, 1.005]`.

`onReport` is **permissionless**: it can only apply the action current prices warrant.
That includes unfreezing, so a manual freeze made while the price is in the unfreeze
band needs `disableAutomation()` to stick.

### State and access control

- `_disabled` — excludes the robot from automation (`checkUpkeep` and `onReport` stand
  down).
- `disableAutomation()` — owner or guardian (emergency off-switch). Reverts
  `AutomationStatusUnchanged` if already disabled.
- `enableAutomation()` — owner-only. Reverts `AutomationStatusUnchanged` if not
  disabled.
- Both emit `AutomationDisabled(disabled)`.
- The contract is `Rescuable`; the owner is the rescue guardian.

## Testing

```bash
# from repo root
forge test --match-path 'workflows/gsm-freezer/tests/*.t.sol' --no-match-contract 'Fork' -vvv   # unit
forge test --match-contract 'GsmFreezerReceiverFork' -vvv                                       # fork; needs RPC_MAINNET
cd workflows/gsm-freezer/offchain && bun test                                                    # CRE workflow (bun)
```

The fork suite runs against the live
[`GhoEthereum.GSM_USDC`](https://etherscan.io/address/0x3A3868898305f04beC7FEa77BecFf04C13444112):
it grants `SWAP_FREEZER_ROLE` as governance would, mocks a depeg in the Aave oracle and
checks the robot freezes and then unfreezes the real GSM.

`workflow.test.ts` runs `createReceiverHandler` against a mocked cre-sdk EVM client
(`EvmMock`) for each branch. Requires `bun` on PATH.

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

1. Governance grants `SWAP_FREEZER_ROLE` to each deployed receiver on its GSM. Until
   then `checkUpkeep` returns false, so the workflow can be registered first.
2. Set each deployed address as a `receiver` in
   [`offchain/config.production.json`](offchain/config.production.json) (USDC + USDT).
3. (Re)deploy the CRE workflow through the owner Safe — see
   [`offchain/README.md`](offchain/README.md).

Post-deploy checks (substitute the deployed `<receiver>`):

```bash
cast call <receiver> "owner()(address)" --rpc-url mainnet
cast call <receiver> "GSM()(address)" --rpc-url mainnet
cast call <gsm> "hasRole(bytes32,address)(bool)" $(cast keccak SWAP_FREEZER_ROLE) <receiver> --rpc-url mainnet
```
