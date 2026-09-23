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
  `abi.encode(address[] gsms)`; the robot reads `getAccruedFees()` on each and
  returns the subset with fees as `abi.encode(address[])`. A GSM whose read reverts
  is skipped. Returns `(false, "")` while disabled, with empty `checkData`, or when
  no GSM has fees.
- `onReport(metadata, report)` — decodes `report` as `address[]` and, for every GSM
  that **still** has accrued fees, calls `distributeFeesToTreasury()`. One reverting
  GSM emits `FeeDistributionFailed` and does not block the rest; reverts
  `NothingToDistribute` if nothing was distributed. Re-reading the fees on-chain
  means a stale or forged report can only trigger distributions that are due.
  `FeesDistributed.amount` is the fee balance the GSM reported right before the
  call; a `Gsm4626` also folds its vault excess into the same distribution, so the
  treasury can receive more than that.

The robot holds no target list: the GSMs live in the workflow config and travel in
`checkData`, so adding a GSM is a config change, not a redeploy.

`onReport` is intentionally **permissionless**, like `distributeFeesToTreasury`
itself: the worst a caller can do is send fees to the treasury a little earlier.

### State

- `_disabled` — excludes the robot from automation. `checkUpkeep` and `onReport`
  both stand down while set. Toggled via `setDisabled(disabled)`, owner or guardian.

## Testing

```bash
# from repo root
forge test --match-path 'workflows/gsm-fee-claimer/tests/*.t.sol' --no-match-contract 'Fork' -vvv   # unit
RPC_MAINNET=... forge test --match-contract 'GsmFeeClaimerReceiverFork' -vvv                        # fork
cd workflows/gsm-fee-claimer/offchain && bun test                                                    # CRE workflow (bun)
```

## Deploying

```bash
make deploy-gsm-fee-claimer env=Mainnet dry=1   # simulate
make deploy-gsm-fee-claimer env=Mainnet         # broadcast + verify
```

Owner is the level-1 governance executor and guardian the governance guardian, both
from the address book. After deploying, paste the address into
`offchain/config.production.json` as that network's `receiver`.
