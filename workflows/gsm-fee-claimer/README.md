# GSM Fee Claimer

CRE robot that sends accrued [GSM](https://github.com/aave/gho-core) fees to the
GHO treasury. Native CRE re-implementation of the `bot-gsm-fee-claimer` workflow
and its `GsmFeeDistributor` receiver. One receiver per network, any number of GSMs.

## Layout

```
gsm-fee-claimer/
├── src/
│   ├── GsmFeeClaimerReceiver.sol         # the robot — inherits IAaveCREReceiver, permissionless onReport
│   └── IGsmFeeClaimerReceiver.sol        # robot interface + minimal IGsmFees
├── tests/
│   ├── GsmFeeClaimerReceiver.t.sol       # unit tests (vm.mockCall against the GSMs)
│   └── GsmFeeClaimerReceiver.fork.t.sol  # fork test that drains the live Ethereum GSMs
├── scripts/
│   └── DeployGsmFeeClaimerReceiver.s.sol # stand-alone forge deploy
└── offchain/                             # CRE workflow — see offchain/README.md
```

## On-chain behavior

`GsmFeeClaimerReceiver` implements [`IAaveCREReceiver`](../shared/src/IAaveCREReceiver.sol):

- `checkUpkeep(checkData) → (needed, gsms)` — read-only probe. `checkData` is
  `abi.encode(address[] gsms, uint256 minFees)`; the robot reads `getAccruedFees()` on
  each GSM and returns those holding at least `minFees` as `abi.encode(address[])`. A
  GSM whose read reverts, has no code or returns no data is skipped. Returns
  `(false, "")` while disabled, with empty `checkData`, or when no GSM qualifies.
- `onReport(metadata, report)` — decodes `report` as `address[]` and calls
  `distributeFeesToTreasury()` on each GSM. The GSM emits the authoritative
  `FeesDistributedToTreasury` event; a `Gsm4626` also folds its vault excess into the
  same distribution. A reverting GSM reverts the whole report, which the workflow's
  gas estimate catches before writing. Reverts `Disabled` while disabled.

The robot holds no target list: the GSMs and the threshold live in the workflow config
and travel in `checkData`, so adding a GSM or tuning the threshold is a config change,
not a redeploy.

`onReport` is intentionally **permissionless**, like `distributeFeesToTreasury`
itself: the worst a caller can do is send fees to the treasury a little earlier.

### State

- `_disabled` — excludes the robot from automation. `checkUpkeep` and `onReport`
  both stand down while set. Toggled via `setDisabled(disabled)`, owner or guardian.

The contract never holds tokens (the GSM pays the treasury directly), so unlike
`FeeSharesMinter` it does not include `Rescuable`.

## Testing

```bash
# from repo root
forge test --match-path 'workflows/gsm-fee-claimer/tests/*.t.sol' --no-match-contract 'Fork' -vvv   # unit
RPC_MAINNET=... forge test --match-contract 'GsmFeeClaimerReceiverFork' -vvv                        # fork
make test-offchain-gsm-fee-claimer                                                                 # CRE workflow (bun)
```

## Deploying

One receiver per network. The script picks owner and guardian from the address book
for the chain it runs on (level-1 governance executor and governance guardian):

```bash
make deploy-gsm-fee-claimer env=Mainnet dry=1    # simulate
make deploy-gsm-fee-claimer env=Mainnet          # broadcast + verify
make deploy-gsm-fee-claimer env=Arbitrum
make deploy-gsm-fee-claimer env=Plasma
make deploy-gsm-fee-claimer env=Monad
```

Plasma and Monad have no explorer entry in `foundry.toml`, so verification there is
manual. After deploying, paste the address into `offchain/config.production.json` as
that network's `receiver`.
