# aave-robots-cre

On-chain receivers and off-chain Chainlink Runtime Environment (CRE) workflows for Aave automation robots.

This repo is the long-term home for **all** Aave CRE automations. Work is organized under `workflows/`, one folder per workflow/robot, with any Solidity (receiver/deploy scripts) and the TypeScript CRE workflow co-located.

## What's here

| Workflow | Folder | What it does |
| --- | --- | --- |
| Automation (protocol robots) | [`workflows/automation`](workflows/automation) | Generic CRE engine that drives the **existing, already-deployed** Aave protocol robots (StataToken Rewards, Slashing, GSM Freezer, Cap Agent, Proof of Reserve) across 7 networks, routing writes through `MailboxCRE`. |
| MailboxCRE | [`workflows/mailbox`](workflows/mailbox) | The on-chain receiver contract + per-chain deploy scripts + deployed-address registry. |

See each folder's README for details.

## How it works

The existing robots only expose the legacy Chainlink Automation interface
(`checkUpkeep` / `performUpkeep`), not the CRE `onReport`. So the automation
workflow connects CRE to them through a generic adapter, `MailboxCRE`:

```
CRE workflow (cron, per network)
  └─ checkUpkeep(robot)               # off-chain read, directly on the robot
       └─ [upkeep needed]
            └─ estimateGas → runtime.report()   # sign & encode (target, calldata)
                 └─ writeReport → MailboxCRE.onReport()
                                      └─ robot.performUpkeep()
```

Reads (`checkUpkeep`) hit the robot directly; only writes go through the Mailbox.
The robots are permissionless, so the Mailbox is a permissionless forwarder.

## Layout

```
workflows/
├── project.yaml                       # CRE project settings — one target per network (rpcs, owner)
├── automation/                        # generic engine + per-network robot lists
│   ├── main.ts, handlers.ts, processAutomation.ts, types.ts
│   ├── workflow.yaml                  # one target per network
│   └── config.<chain>-agents.json     # robots to automate on each chain
├── contracts/abi/                     # ABIs the engine uses (ICLAutomation, IMailboxCRE)
├── mailbox/                           # MailboxCRE receiver
│   ├── src/MailboxCRE.sol
│   ├── scripts/MailboxCRE.s.sol       # one Deploy<Chain> per network
│   └── README.md                      # deployed-address registry
└── shared/src/IReceiver.sol           # vendored Chainlink keystone receiver interface
```

## Networks & robots

7 networks, 19 robots, all referenced **by address** (no robot is redeployed):
ethereum (5), polygon (2), optimism (2), arbitrum (2), base (2), bnb (2),
avalanche (4). The full per-chain list lives in the `config.<chain>-agents.json`
files; the deployed `MailboxCRE` addresses are in
[`workflows/mailbox/README.md`](workflows/mailbox/README.md).

## Workflow ownership

CRE workflows are registered and owned by a multisig on the Chainlink
[`WorkflowRegistry`](https://github.com/smartcontractkit/chainlink-evm/blob/develop/contracts/cre/src/v2/WorkflowRegistry.sol)
(Ethereum mainnet, `0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5`). Lifecycle
actions (register/update, activate, pause, delete) are produced as **unsigned**
transactions and proposed through that owner.

`workflow-owner-address` in [`workflows/project.yaml`](workflows/project.yaml) is
currently left blank: the intended owner is a "proxied guardian" contract that
splits ownership between a guardian Safe and the executor — set its address on
all targets once it is deployed (look for the `TODO` markers).

## Build, simulate & deploy

```bash
make install                       # npm install + bun install (workflows/automation)

make simulate chain=ethereum       # simulate a network's workflow (trigger picker)
make simulate-one chain=avalanche i=3   # simulate a single robot non-interactively

make deploy chain=ethereum         # cre workflow deploy ... --unsigned (prints tx for the Safe)
make activate chain=ethereum       # cre workflow activate ... --unsigned
```

`make lint` / `make lint-fix` run prettier over `workflows/`.

RPC endpoints come from `.env` (`${RPC_URL_<CHAIN>}`); see [`.env.example`](.env.example).

## Dependencies

Solidity dependencies (for `MailboxCRE`) come through
[`aave-helpers`](https://github.com/aave-dao/aave-helpers) as a git submodule,
which transitively pulls `openzeppelin-contracts` and friends via
[`remappings.txt`](remappings.txt):

```bash
git submodule update --init --recursive
```

The off-chain workflow uses [`bun`](https://bun.sh) + `@chainlink/cre-sdk`
(installed by `make install`).
