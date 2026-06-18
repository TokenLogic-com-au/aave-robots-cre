# aave-robots-cre

On-chain receivers and off-chain Chainlink Runtime Environment (CRE) workflows for Aave automation robots.

This repo is the long-term home for **all** Aave CRE automations. Each robot lives in its own folder under `workflows/`, with the Solidity contracts, tests, deploy script, and TypeScript CRE workflow co-located so it's self-contained.

## Robots

| Robot           | Folder                                                       | What it does                                                                       |
| --------------- | ------------------------------------------------------------ | ---------------------------------------------------------------------------------- |
| FeeSharesMinter | [`workflows/fee-shares-minter`](workflows/fee-shares-minter) | Mints accrued fee shares on Aave v4 hubs once a configurable threshold is crossed. |

See each robot's README for the contract design, test instructions, deploy flow and CRE workflow config.

## Layout

```
workflows/
├── project.yaml, secrets.yaml         # CRE project-wide settings (rpcs, secret refs)
├── shared/                            # reused across every robot
│   ├── src/
│   │   ├── IReceiver.sol              # vendored Chainlink keystone interface
│   │   └── IAaveCREReceiver.sol       # IReceiver + checkUpkeep — base for every robot
│   └── offchain/
│       └── checkUpkeep.ts             # generic checkUpkeep → sign → writeReport helper
└── <robot-name>/                      # one folder per robot — onchain + offchain co-located
    ├── README.md                      # robot-specific docs
    ├── src/                           # Solidity contracts
    ├── tests/                         # Solidity tests (unit + fork)
    ├── scripts/                       # forge deploy scripts
    └── offchain/                      # the CRE workflow (main.ts, workflow.yaml, configs, …)
```

## On-chain contract — `IAaveCREReceiver`

Every robot in this repo MUST inherit [`IAaveCREReceiver`](workflows/shared/src/IAaveCREReceiver.sol), which exposes two surfaces:

- `onReport(metadata, report)` — from `IReceiver`. The CRE forwarder calls this when a workflow delivers a signed report. `metadata` carries the workflow id, owner and name; the forwarder identity is `msg.sender`. Implementations choose between permissioned (validate the metadata fields against an allowlist and pin `msg.sender` to a configured forwarder address) and permissionless (ignore both) depending on whether restricting _delivery_ offers any security on top of the action itself.
- `checkUpkeep(checkData) → (upkeepNeeded, performData)` — borrowed from the legacy Chainlink Automation interface. The off-chain workflow uses it as a cheap read-only probe: if `upkeepNeeded`, it signs `performData` and submits it as `report`.

The Solidity interface is the single source of truth for both sides. The off-chain code imports a checked-in `as const` ABI from [`workflows/shared/offchain/abi/IAaveCREReceiver.ts`](workflows/shared/offchain/abi/IAaveCREReceiver.ts), generated from the foundry build artifact by [`workflows/shared/offchain/generate-abis.mjs`](workflows/shared/offchain/generate-abis.mjs):

```bash
npm run generate-abis   # runs `forge build` then writes workflows/shared/offchain/abi/*.ts
```

The generated TS file is committed, so workflows type-check and bundle without needing a fresh `forge build`. To add another robot ABI, append its name to the `ABIS` list at the top of `generate-abis.mjs`. CI fails if the committed ABIs are stale vs the Solidity sources.

## Workflow ownership

CRE workflows are registered and owned by a multisig Safe on the Chainlink [`WorkflowRegistry`](https://github.com/smartcontractkit/chainlink-evm/blob/develop/contracts/cre/src/v2/WorkflowRegistry.sol) (Ethereum mainnet, `0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5`). The Safe is the registry-level workflow owner, so workflow lifecycle actions (register/update, activate, pause, delete) are produced as unsigned transactions and proposed through the Safe. See the per-robot offchain README for the `--unsigned` helper scripts.

## Dependencies

Solidity dependencies come through [`aave-helpers`](https://github.com/aave-dao/aave-helpers) as a git submodule. That transitively pulls `aave-address-book`, `aave-v3-origin`, `aave-v4`, `solidity-utils` and `openzeppelin-contracts`, all reachable via [`remappings.txt`](remappings.txt).

```bash
git submodule update --init --recursive
```

### npm — 7-day maturity gate + exact pins

[`.npmrc`](./.npmrc) enforces:

- `min-release-age=30` — installed package versions must have been on the registry for at least 30 days (npm 11+; value is in days).
- `save-exact=true` — installs pin exact versions (no `^` / `~`).
- `engine-strict=false` — engine mismatches warn instead of failing, so installs work on the npm bundled with Node 22 (npm 10); npm 11 is still recommended for `min-release-age` to apply.

All packages in the tree are pinned exactly. Adding a dependency requires waiting out the 30-day maturity gate before the lockfile can resolve.

## Building & testing

```bash
make install        # forge install + npm install (root + each workflow's offchain/)
make build          # forge build --sizes — produces ABI artifacts in out/
make test-unit      # forge test, excluding fork tests
make test-fork      # RPC_MAINNET=... make test-fork
make test           # both
```

Per-workflow TS typechecks and offchain unit tests are wired separately (e.g. `make typecheck-fee-shares-minter`, `make test-offchain-fee-shares-minter`). Typechecks require `make build` first. Offchain tests use the cre-sdk's `EvmMock` to stub the EVM client and exercise the workflow handler end-to-end against canned responses; they run on `bun` (must be on `PATH`).

Generic offchain test helpers (`encodeCheckUpkeepResult`, `mockLog`, `mockReceipt`) live in [`workflows/shared/offchain/testing/mocks.ts`](workflows/shared/offchain/testing/mocks.ts) and are reusable from any robot's `workflow.test.ts`.

CI (`.github/workflows/main.yml`) runs the foundry suite (unit + fork tests), the TS typecheck, and the offchain bun tests on every PR. `secrets.ALCHEMY_API_KEY` must be available to the workflow (typically inherited from the org); CI constructs `RPC_MAINNET` from it for the fork-tests step, which fails hard if the secret is missing. The fork test itself only reads `RPC_MAINNET` — no hardcoded provider.

## Deploying

Deployments use a foundry-managed keystore account. Create one with `cast wallet import <name>`, set `ACCOUNT_NAME=<name>` in `.env`, then run the per-robot make targets (e.g. `make deploy-fee-shares-minter env=Mainnet dry=true` to simulate, `make deploy-fee-shares-minter env=Mainnet` to broadcast). See each robot's README for the available targets.

## Adding a new robot

1. Create `workflows/<robot-name>/`.
2. `src/` — robot contract inheriting `IAaveCREReceiver` (`import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';`), plus an `I<RobotName>.sol` interface that inherits `IAaveCREReceiver`.
3. `tests/` — unit tests (mock dependencies) and a `*Fork*` test (filename `<Robot>.fork.t.sol`, contract name ending in `Fork`).
4. `scripts/` — a forge deploy script. Stand-alone — robots are NOT part of any v3/v4 deployment / config engine.
5. `offchain/` — the CRE workflow. Required files: `main.ts` (entry point), `workflow.ts` (handler + config schema), `workflow.yaml` (CRE workflow settings, with a `workflow-name` unique to this robot), `config.staging.json` / `config.production.json`, plus its own `package.json` and `tsconfig.json` (the latter must include `../../shared/offchain/**/*.ts`). See [`workflows/fee-shares-minter/offchain`](workflows/fee-shares-minter/offchain) for a reference shape. The shared `checkAndReport` helper is reusable when `onReport` is permissionless and the robot's `performData` is exactly the bytes you'd pass as `report`; for Mailbox-style permissioned `onReport`, write the post-`checkUpkeep` step in the workflow itself.
6. Add a row to the **Robots** table above with a link to the new folder's README.
