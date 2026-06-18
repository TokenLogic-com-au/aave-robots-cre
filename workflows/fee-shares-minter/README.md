# FeeSharesMinter

CRE robot that mints accrued fee shares on Aave v4 Hubs once the ratio of accrued fees to total added assets crosses an owner-configured threshold — preventing supply-share inflation when a hub goes a long time between fee mints.

## Layout

```
fee-shares-minter/
├── src/
│   ├── FeeSharesMinter.sol         # the robot — inherits IAaveCREReceiver, permissionless onReport
│   └── IFeeSharesMinter.sol
├── tests/
│   ├── FeeSharesMinter.t.sol       # unit tests (vm.mockCall against IHub)
│   ├── FeeSharesMinter.fork.t.sol  # fork tests against AaveV4EthereumHubs.CORE_HUB
│   └── helpers/
│       └── MockHubHelpers.sol
├── scripts/
│   └── DeployFeeSharesMinter.s.sol # stand-alone forge deploy
└── offchain/                       # CRE workflow — see offchain/README.md
```

## On-chain behavior

`FeeSharesMinter` implements [`IAaveCREReceiver`](../shared/src/IAaveCREReceiver.sol):

- `checkUpkeep((hub, assetId)) → (canMint, sameBytes)` — read-only probe used by the off-chain workflow.
- `onReport(metadata, (hub, assetId))` — calls `IHub(hub).mintFeeShares(assetId)` when the threshold is crossed.

`onReport` is intentionally **permissionless**: `metadata` (workflow id / owner / name) and `msg.sender` (the forwarder) are both ignored. Justification — the underlying action is already gated by:

1. The owner-configured per-asset ratio threshold (`updateFeesToAssetsThreshold`).
2. The on-chain `HUB_FEE_MINTER_ROLE` check on the Hub itself.
3. The shares-round-to-non-zero guard inside `_canMint`.

### State

- `_feesToAssetsThreshold[hub][assetId]` — per-(hub, asset) BPS threshold (`PercentageMath.PERCENTAGE_FACTOR` max; 0 disables minting).
- Set via `updateFeesToAssetsThreshold(hub, assetId, feesToAssetsThreshold)` — owner-only, validates that the asset is listed on the hub.

### Mint conditions (`_canMint`)

Returns `true` only when **all** of:

- Threshold is configured (non-zero).
- `getAddedAssets(assetId) > 0`.
- `getAssetAccruedFees(assetId) / getAddedAssets(assetId) ≥ threshold` (BPS).
- `previewAddByAssets(assetId, accruedFees) > 0` (i.e. the mint would actually produce ≥ 1 share).

## Testing

```bash
# from repo root
forge test --match-path 'workflows/fee-shares-minter/tests/*.t.sol' --no-match-contract 'Fork' -vvv   # unit
RPC_MAINNET=... forge test --match-contract 'FeeSharesMinterFork' -vvv --ffi                          # fork
make test-offchain-fee-shares-minter                                                                  # CRE workflow (bun)
```

The fork suite forks Ethereum mainnet against [`AaveV4EthereumHubs.CORE_HUB`](https://etherscan.io/address/0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9), grants `HUB_FEE_MINTER_ROLE` to a fresh minter via the live AccessManager admin, and exercises both the revert path (unconfigured asset → `ConditionsNotMet`) and the permissionless mint path (scans for an asset whose live ratio is mintable; skips if none is). It skips entirely when `RPC_MAINNET` is unset.

`workflow.test.ts` mocks the cre-sdk EVM client via `EvmMock` and drives `createTargetHandler` end-to-end for each branch (no upkeep, gas-estimate revert, happy path with a decoded `MintFeeShares` event, missing event, log from wrong address). Generic helpers used by the test (`encodeCheckUpkeepResult`, `mockLog`, `mockReceipt`) live in [`../shared/offchain/testing/mocks.ts`](../shared/offchain/testing/mocks.ts) and are reusable from any robot's offchain tests. Requires `bun` on PATH.

## Deployment

`FeeSharesMinter` deploys stand-alone — it's not part of the v4 deployment / config engine. Signing uses a foundry-managed keystore account (`cast wallet import <name>`), referenced via `ACCOUNT_NAME` in `.env`.

```bash
# from repo root, with ACCOUNT_NAME=<your-keystore-name> in .env
make deploy-fee-shares-minter env=Mainnet dry=true   # simulate
make deploy-fee-shares-minter env=Mainnet            # broadcast — prompts for keystore password
```

`DeployFeeSharesMinter` in `scripts/DeployFeeSharesMinter.s.sol` uses `GovernanceV3Ethereum.EXECUTOR_LVL_1` as owner and `GovernanceV3Ethereum.GOVERNANCE_GUARDIAN` as guardian; copy and adapt for other chains.

### Post-deploy

1. Governance grants `HUB_FEE_MINTER_ROLE` (id `102`) to the deployed minter on the relevant AccessManager.
2. Owner calls `updateFeesToAssetsThreshold(hub, assetId, feesToAssetsThreshold)` for each `(hub, asset)` pair to enable.
3. Add the deployment + per-asset targets to [`offchain/config.production.json`](offchain/config.production.json) and (re)deploy the CRE workflow — see [`offchain/README.md`](offchain/README.md).

Post-deploy checks (substitute the deployed `<minter>`, the `<accessManager>`, and an enabled `<hub>`/`<assetId>`):

```bash
cast call <minter> "owner()(address)" --rpc-url mainnet
cast call <minter> "guardian()(address)" --rpc-url mainnet
cast call <accessManager> "hasRole(uint64,address)(bool,uint32)" 102 <minter> --rpc-url mainnet
cast call <minter> "getFeesToAssetsThreshold(address,uint256)(uint16)" <hub> <assetId> --rpc-url mainnet
```
