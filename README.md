# aave-robots-cre

On-chain receivers and off-chain Chainlink Runtime Environment (CRE) workflows for Aave automation robots.

This repo is the long-term home for **all** Aave CRE automations, organized under `workflows/` - both **native** robots (a contract implementing `IAaveCREReceiver` + its workflow, co-located) and the **migration** automation that drives the existing, already-deployed protocol robots through a generic `MailboxCRE`.

## Robots

| Robot | Folder | What it does |
| --- | --- | --- |
| FeeSharesMinter | [`workflows/fee-shares-minter`](workflows/fee-shares-minter) | Native robot - mints accrued fee shares on Aave v4 hubs once a configurable threshold is crossed. |
| Automation (protocol robots) | [`workflows/automation`](workflows/automation) | Generic CRE engine driving the **existing, already-deployed** protocol robots (StataToken Rewards, Slashing, GSM Freezer, Cap Agent, Proof of Reserve) across 7 networks - referenced by address, writes routed through `MailboxCRE`. |
| MailboxCRE | [`workflows/mailbox`](workflows/mailbox) | The on-chain receiver/forwarder used by the automation workflow + per-chain deploy scripts + deployed-address registry. |

See each folder's README for the contract design, test instructions, deploy flow and CRE workflow config.
`
## Deployed automation robots

Existing protocol/governance robots driven through `MailboxCRE` (referenced by
address, none redeployed). All workflows are owned by the proxied-guardian Safe
`0x73494691C9B28b91A0b4C9dF213c1893fddA3a3B` on the CRE `WorkflowRegistry`.

### Protocol robots (live)

| Robot | Network | Address | CRE Workflow |
| --- | --- | --- | --- |
| StataToken Rewards (Core) | Ethereum | `0x892B74CD3703B427CD90e7f140F358A1DE1EA703` | [agents-1](https://app.chain.link/cre/workflows/0fc6cf62-a2b7-4ea7-a20e-b90dd540212a) |
| StataToken Rewards (Prime) | Ethereum | `0x858f50cB70e6476d37543275aF4c738Ae8a27893` | [agents-1](https://app.chain.link/cre/workflows/0fc6cf62-a2b7-4ea7-a20e-b90dd540212a) |
| Slashing | Ethereum | `0x4216d695070ce243e48A3bB0646CaA4DDB81B957` | [agents-1](https://app.chain.link/cre/workflows/0fc6cf62-a2b7-4ea7-a20e-b90dd540212a) |
| GSM Freezer (USDC) | Ethereum | `0x6e51936e0ED4256f9dA4794B536B619c88Ff0047` | [agents-1](https://app.chain.link/cre/workflows/0fc6cf62-a2b7-4ea7-a20e-b90dd540212a) |
| GSM Freezer (USDT) | Ethereum | `0x733AB16005c39d07FD3D9d1A350AA6768D10125b` | [agents-1](https://app.chain.link/cre/workflows/0fc6cf62-a2b7-4ea7-a20e-b90dd540212a) |
| StataToken Rewards | Avalanche | `0x43C6b39669355AF93DdEdc70e8eB44c226f09BFB` | [agents-1](https://app.chain.link/cre/workflows/0fc6cf62-a2b7-4ea7-a20e-b90dd540212a) |
| Cap Agent | Avalanche | `0xe4E91893Dd64c48FC2F20410F37f203259ECA896` | [agents-1](https://app.chain.link/cre/workflows/0fc6cf62-a2b7-4ea7-a20e-b90dd540212a) |
| Proof of Reserve | Avalanche | `0x7aE2930B50CFEbc99FE6DB16CE5B9C7D8d09332C` | [agents-1](https://app.chain.link/cre/workflows/0fc6cf62-a2b7-4ea7-a20e-b90dd540212a) |
| Proof of Reserve (V2) | Avalanche | `0x7aE2930B50CFEbc99FE6DB16CE5B9C7D8d09332C` | [agents-1](https://app.chain.link/cre/workflows/0fc6cf62-a2b7-4ea7-a20e-b90dd540212a) |
| StataToken Rewards | Polygon | `0x1d8347B427964fad8a742e7f9442a4E89346400a` | [agents-2](https://app.chain.link/cre/workflows/f2a92ab7-170b-46dd-b166-b0f8c0f7f36b) |
| Cap Agent | Polygon | `0x125844D33F75090517Ea19Aab8Ca24eEa4Fef764` | [agents-2](https://app.chain.link/cre/workflows/f2a92ab7-170b-46dd-b166-b0f8c0f7f36b) |
| StataToken Rewards | Optimism | `0x365d47ceD3D7Eb6a9bdB3814aA23cc06B2D33Ef8` | [agents-2](https://app.chain.link/cre/workflows/f2a92ab7-170b-46dd-b166-b0f8c0f7f36b) |
| Cap Agent | Optimism | `0xEed80d79ae1383884b93d96bd1521F7247EC7e53` | [agents-2](https://app.chain.link/cre/workflows/f2a92ab7-170b-46dd-b166-b0f8c0f7f36b) |
| StataToken Rewards | Arbitrum | `0xF01281a6DfDe5506C5049c9BBf8C7E087b9bD4bF` | [agents-2](https://app.chain.link/cre/workflows/f2a92ab7-170b-46dd-b166-b0f8c0f7f36b) |
| Cap Agent | Arbitrum | `0xFf822f7E2178176bB650df82427a42cA0c04CcaB` | [agents-2](https://app.chain.link/cre/workflows/f2a92ab7-170b-46dd-b166-b0f8c0f7f36b) |
| StataToken Rewards | Base | `0x97CB9e81d480A2AB03299760654C1DDC0C16bE07` | [agents-2](https://app.chain.link/cre/workflows/f2a92ab7-170b-46dd-b166-b0f8c0f7f36b) |
| Cap Agent | Base | `0x78C2eCf3Ad48F90350f42EB338675cA1b31a7f11` | [agents-2](https://app.chain.link/cre/workflows/f2a92ab7-170b-46dd-b166-b0f8c0f7f36b) |
| StataToken Rewards | BNB | `0x9062F78b631f33D24Ed058cBc116A653452ea82A` | [agents-2](https://app.chain.link/cre/workflows/f2a92ab7-170b-46dd-b166-b0f8c0f7f36b) |
| Cap Agent | BNB | `0x78C2eCf3Ad48F90350f42EB338675cA1b31a7f11` | [agents-2](https://app.chain.link/cre/workflows/f2a92ab7-170b-46dd-b166-b0f8c0f7f36b) |

### Governance robots (live)

| Robot | Network | Address | CRE Workflow |
| --- | --- | --- | --- |
| Gas Capped Execution Chain Robot | Ethereum | `0xBa37F9eDC52f57caFA3a13ddfD655797Cc4FE257` | [gov-1](https://app.chain.link/cre/workflows/d159dc83-cc98-4bff-aa85-3327a2e3bc42) |
| Gas Capped Governance Chain Robot | Ethereum | `0x1996c281235D99bB3c6B8d2afbEb8ac6c7A39C11` | [gov-1](https://app.chain.link/cre/workflows/d159dc83-cc98-4bff-aa85-3327a2e3bc42) |
| Gas Capped Voting Chain Robot | Ethereum | `0xbC3210bfff692a5bbDBB068D42Ab4eAF28b01Ee0` | [gov-1](https://app.chain.link/cre/workflows/d159dc83-cc98-4bff-aa85-3327a2e3bc42) |
| Execution Chain Robot | Avalanche | `0x7B74938583Eb03e06042fcB651046BaF0bf15644` | [gov-1](https://app.chain.link/cre/workflows/d159dc83-cc98-4bff-aa85-3327a2e3bc42) |
| Voting Chain Robot | Avalanche | `0x2cf0fA5b36F0f89a5EA18F835d1375974a7720B8` | [gov-1](https://app.chain.link/cre/workflows/d159dc83-cc98-4bff-aa85-3327a2e3bc42) |
| Execution Chain Robot | Polygon | `0x249396a890F89D47F89326d7EE116b1d374fb3A9` | [gov-2](https://app.chain.link/cre/workflows/d96b69de-ba5e-4c58-abae-0d2dace3617f) |
| Voting Chain Robot | Polygon | `0x1180eE41eC15Dd0accC13a1e646B3152bECFf8F6` | [gov-2](https://app.chain.link/cre/workflows/d96b69de-ba5e-4c58-abae-0d2dace3617f) |
| Execution Chain Robot | Optimism | `0xa0195539e21A6553243344A3BE6b874B5d3EC7b9` | [gov-2](https://app.chain.link/cre/workflows/d96b69de-ba5e-4c58-abae-0d2dace3617f) |
| Execution Chain Robot | Arbitrum | `0x64093fe5f8Cf62aFb4377cf7EF4373537fe9155B` | [gov-2](https://app.chain.link/cre/workflows/d96b69de-ba5e-4c58-abae-0d2dace3617f) |
| Execution Chain Robot | Base | `0xdb93e2712a8B36835078f8D28c70fCC95FD6d37c` | [gov-2](https://app.chain.link/cre/workflows/d96b69de-ba5e-4c58-abae-0d2dace3617f) |
| Execution Chain Robot | BNB | `0x870F5EBf5C13B73251283b2d883988066e2bb732` | [gov-2](https://app.chain.link/cre/workflows/d96b69de-ba5e-4c58-abae-0d2dace3617f) |

`MailboxCRE` addresses per chain are listed in [`workflows/mailbox/README.md`](workflows/mailbox/README.md).

## Two patterns

- **Native** (e.g. FeeSharesMinter): the robot contract implements `IAaveCREReceiver` directly, so CRE writes its signed report straight to `onReport`. New robots are built this way.
- **Migration** (`workflows/automation`): the existing robots only expose the legacy Chainlink Automation interface (`checkUpkeep` / `performUpkeep`), not `onReport`. The generic engine calls `checkUpkeep` off-chain and, when work is needed, writes a signed report to `MailboxCRE`, which decodes `(target, calldata)` and forwards `performUpkeep`. Robots are referenced by address - none is redeployed. Owner of those workflows is the proxied-guardian Safe set in [`workflows/project.yaml`](workflows/project.yaml).

## Layout

```
workflows/
├── project.yaml, secrets.yaml         # CRE project-wide settings (rpcs, owner, secret refs)
├── shared/                            # reused across native robots
│   ├── src/
│   │   ├── IReceiver.sol              # vendored Chainlink keystone interface
│   │   └── IAaveCREReceiver.sol       # IReceiver + checkUpkeep - base for native robots
│   └── offchain/
│       └── checkUpkeep.ts             # generic checkUpkeep → sign → writeReport helper
├── automation/                        # migration engine + per-network robot lists
│   ├── main.ts, handlers.ts, processAutomation.ts, types.ts
│   ├── workflow.yaml                  # one target per network
│   └── config.*.json                  # robot groups (agents-1/2, gov-1/2)
├── contracts/abi/                     # ABIs the migration engine uses (ICLAutomation, IMailboxCRE)
├── mailbox/                           # MailboxCRE receiver/forwarder + deploy scripts + registry
└── <robot-name>/                      # one folder per native robot - onchain + offchain co-located
    ├── README.md
    ├── src/                           # Solidity contracts
    ├── tests/                         # Solidity tests (unit + fork)
    ├── scripts/                       # forge deploy scripts
    └── offchain/                      # the CRE workflow (main.ts, workflow.yaml, configs, …)
```

## On-chain contract — `IAaveCREReceiver`

Native robots MUST inherit [`IAaveCREReceiver`](workflows/shared/src/IAaveCREReceiver.sol), which exposes two surfaces:

- `onReport(metadata, report)` — from `IReceiver`. The CRE forwarder calls this when a workflow delivers a signed report. `metadata` carries the workflow id, owner and name; the forwarder identity is `msg.sender`. Implementations choose between permissioned (validate the metadata fields against an allowlist and pin `msg.sender` to a configured forwarder address) and permissionless (ignore both) depending on whether restricting _delivery_ offers any security on top of the action itself.
- `checkUpkeep(checkData) → (upkeepNeeded, performData)` — borrowed from the legacy Chainlink Automation interface. The off-chain workflow uses it as a cheap read-only probe: if `upkeepNeeded`, it signs `performData` and submits it as `report`.

The Solidity interface is the single source of truth for both sides. The off-chain code imports a checked-in `as const` ABI from [`workflows/shared/offchain/abi/IAaveCREReceiver.ts`](workflows/shared/offchain/abi/IAaveCREReceiver.ts), generated from the foundry build artifact by [`workflows/shared/offchain/generate-abis.mjs`](workflows/shared/offchain/generate-abis.mjs):

```bash
npm run generate-abis   # runs `forge build` then writes workflows/shared/offchain/abi/*.ts
```

The generated TS file is committed, so workflows type-check and bundle without needing a fresh `forge build`. To add another robot ABI, append its name to the `ABIS` list at the top of `generate-abis.mjs`. CI fails if the committed ABIs are stale vs the Solidity sources.

The migration automation does **not** use `IAaveCREReceiver` on the robots (they predate it); it uses `MailboxCRE` as the receiver instead - see [`workflows/mailbox`](workflows/mailbox) and [`workflows/automation`](workflows/automation).

## Workflow ownership

CRE workflows are registered and owned by a multisig Safe on the Chainlink [`WorkflowRegistry`](https://github.com/smartcontractkit/chainlink-evm/blob/develop/contracts/cre/src/v2/WorkflowRegistry.sol) (Ethereum mainnet, `0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5`). The Safe is the registry-level workflow owner, so workflow lifecycle actions (register/update, activate, pause, delete) are produced as unsigned transactions and proposed through the Safe. The automation-agents targets in [`workflows/project.yaml`](workflows/project.yaml) are owned by the proxied-guardian Safe `0x73494691C9B28b91A0b4C9dF213c1893fddA3a3B`.

## Dependencies

Solidity dependencies come through [`aave-helpers`](https://github.com/aave-dao/aave-helpers) as a git submodule. That transitively pulls `aave-address-book`, `aave-v3-origin`, `aave-v4`, `solidity-utils` and `openzeppelin-contracts`, all reachable via [`remappings.txt`](remappings.txt).

```bash
git submodule update --init --recursive
```

### npm - maturity gate + exact pins

[`.npmrc`](./.npmrc) enforces:

- `min-release-age=30` — installed package versions must have been on the registry for at least 30 days (npm 11+; value is in days).
- `save-exact=true` — installs pin exact versions (no `^` / `~`).
- `engine-strict=false` — engine mismatches warn instead of failing, so installs work on the npm bundled with Node 22 (npm 10); npm 11 is still recommended for `min-release-age` to apply.

All packages in the tree are pinned exactly. Adding a dependency requires waiting out the maturity gate before the lockfile can resolve.

## Building & testing

```bash
make install        # forge install + npm install (root + each workflow's offchain/ + automation bun)
make build          # forge build --sizes — produces ABI artifacts in out/
make test-unit      # forge test, excluding fork tests
make test-fork      # RPC_MAINNET=... make test-fork
make test           # both
```

Per-workflow TS typechecks and offchain unit tests are wired separately (e.g. `make typecheck-fee-shares-minter`, `make test-offchain-fee-shares-minter`). Typechecks require `make build` first. Offchain tests use the cre-sdk's `EvmMock` to stub the EVM client and exercise the workflow handler end-to-end against canned responses; they run on `bun` (must be on `PATH`).

Generic offchain test helpers (`encodeCheckUpkeepResult`, `mockLog`, `mockReceipt`) live in [`workflows/shared/offchain/testing/mocks.ts`](workflows/shared/offchain/testing/mocks.ts) and are reusable from any robot's `workflow.test.ts`.

For the migration automation: `make simulate target=agents-1` (or `make simulate-one target=agents-1 i=3`) runs a workflow against mainnet; `make deploy-automation target=agents-1` / `make activate-automation target=agents-1` produce the unsigned lifecycle tx for the owner Safe.

CI (`.github/workflows/main.yml`) runs the foundry suite (unit + fork tests), the TS typecheck, and the offchain bun tests on every PR. `secrets.ALCHEMY_API_KEY` must be available to the workflow (typically inherited from the org); CI constructs `RPC_MAINNET` from it for the fork-tests step, which fails hard if the secret is missing. The fork test itself only reads `RPC_MAINNET` — no hardcoded provider.

## Deploying

Native-robot deployments use a foundry-managed keystore account. Create one with `cast wallet import <name>`, set `ACCOUNT_NAME=<name>` in `.env`, then run the per-robot make targets (e.g. `make deploy-fee-shares-minter env=Mainnet dry=true` to simulate, `make deploy-fee-shares-minter env=Mainnet` to broadcast). See each robot's README for the available targets.

The migration automation workflows are deployed through the owner Safe via `cre workflow deploy ... --unsigned` (`make deploy-automation target=<target>`); `MailboxCRE` itself ships with per-chain forge deploy scripts in [`workflows/mailbox`](workflows/mailbox).

## Adding a new robot

1. Create `workflows/<robot-name>/`.
2. `src/` — robot contract inheriting `IAaveCREReceiver` (`import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';`), plus an `I<RobotName>.sol` interface that inherits `IAaveCREReceiver`.
3. `tests/` — unit tests (mock dependencies) and a `*Fork*` test (filename `<Robot>.fork.t.sol`, contract name ending in `Fork`).
4. `scripts/` — a forge deploy script. Stand-alone — robots are NOT part of any v3/v4 deployment / config engine.
5. `offchain/` — the CRE workflow. Required files: `main.ts` (entry point), `workflow.ts` (handler + config schema), `workflow.yaml` (CRE workflow settings, with a `workflow-name` unique to this robot), `config.staging.json` / `config.production.json`, plus its own `package.json` and `tsconfig.json` (the latter must include `../../shared/offchain/**/*.ts`). See [`workflows/fee-shares-minter/offchain`](workflows/fee-shares-minter/offchain) for a reference shape. The shared `checkAndReport` helper is reusable when `onReport` is permissionless and the robot's `performData` is exactly the bytes you'd pass as `report`; for Mailbox-style permissioned `onReport`, write the post-`checkUpkeep` step in the workflow itself.
6. Add a row to the **Robots** table above with a link to the new folder's README.

> To automate an **already-deployed** robot instead of building a new contract, add it to the relevant `workflows/automation/config.*.json` (see [`workflows/automation`](workflows/automation)) rather than creating a new folder.
