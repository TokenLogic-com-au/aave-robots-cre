# Aave Robots - CRE Automation Workflow

This workflow uses the Chainlink Runtime Environment (CRE) to automate the
existing Aave protocol robots. On each cron tick it calls `checkUpkeep` on every
configured robot, and if work is needed it submits a signed CRE report to the
`MailboxCRE` contract which forwards the `performUpkeep` call on-chain.

The engine (`main.ts` + `handlers.ts` + `processAutomation.ts`) is generic and
shared across all networks; each network is just a different config file.

## Architecture

```
CRE Workflow (cron, per network)
  └─ checkUpkeep(robot)          # off-chain read, directly on the robot
       └─ [upkeep needed]
            └─ estimateGas -> runtime.report()  # sign & encode payload
                 └─ writeReport -> MailboxCRE.onReport()
                                       └─ robot.performUpkeep()
```

### MailboxCRE

`MailboxCRE` ([../mailbox/src/MailboxCRE.sol](../mailbox/src/MailboxCRE.sol)) is
the on-chain receiver. It implements the CRE `IReceiver` interface and, on
`onReport`, ABI-decodes the report into `(address target, bytes calldata)` and
calls the target directly. See [../mailbox/README.md](../mailbox/README.md) for
the deployed addresses.

No caller or forwarder checks are enforced - this is intentional. The robot
contracts themselves are permissionless (anyone can call `performUpkeep`), so
restricting who may deliver a report provides no security benefit.

## Config files

One config per network, wired to a workflow target in `workflow.yaml`:

| File | Target |
|------|--------|
| `config.ethereum-agents.json` | `ethereum-agents-production-settings` |
| `config.polygon-agents.json` | `polygon-agents-production-settings` |
| `config.optimism-agents.json` | `optimism-agents-production-settings` |
| `config.arbitrum-agents.json` | `arbitrum-agents-production-settings` |
| `config.base-agents.json` | `base-agents-production-settings` |
| `config.bnb-agents.json` | `bnb-agents-production-settings` |
| `config.avalanche-agents.json` | `avalanche-agents-production-settings` |

> Configs are split per network because CRE caps a workflow at 10 trigger
> subscriptions (one per robot).

### Config schema

```jsonc
{
  "schedule": "*/5 * * * *",   // cron expression for how often to run
  "evms": [
    {
      "chainName": "ethereum-mainnet",             // CRE chain selector name
      "mailboxAddress": "0x...",                   // deployed MailboxCRE address
      "automations": [
        {
          "address": "0x...",                      // robot contract address
          "checkData": "0x",                       // passed to checkUpkeep (use "0x" if unused)
          "name": "StataToken Rewards (Core)"      // optional label, ignored by the engine
        }
      ]
    }
  ]
}
```

> Some robots decode `checkData` and revert on empty `0x` - e.g. the Cap Agent
> (`abi.encode(uint256[] agentIds)`) and Proof of Reserve (`abi.encode(address executor)`).
> Those entries carry the proper ABI-encoded `checkData`.

## Setup

If `bun` is not already installed, see https://bun.sh/docs/installation.

```bash
cd workflows/automation && bun install   # or `make install` from the repo root
```

## Simulate

Run from `workflows/` (the directory containing `project.yaml`):

```bash
# interactive trigger picker
cre workflow simulate ./automation --target=ethereum-agents-production-settings

# a single robot, non-interactively (trigger order = config "automations" order)
cre workflow simulate ./automation --target=avalanche-agents-production-settings --non-interactive --trigger-index=3
```

Or via make from the repo root: `make simulate chain=ethereum` /
`make simulate-one chain=avalanche i=3`.

Simulation performs the full off-chain logic including `checkUpkeep` reads and
gas estimation, but does not submit any transactions.

## Deploy

`--unsigned` prints the raw tx for the owner Safe to propose (it does not broadcast):

```bash
cre workflow deploy   ./automation --target=ethereum-agents-production-settings --unsigned
cre workflow activate ./automation --target=ethereum-agents-production-settings --unsigned --yes
```

Or: `make deploy-automation chain=ethereum` / `make activate-automation chain=ethereum`. The workflow
name per target is set in `workflow.yaml` (e.g. `automation-ethereum-agents`).
Deploying again with the same name updates the existing workflow.

## Adding a robot / network

1. Add an entry to the `automations` array in the relevant `config.<chain>-agents.json`
   (or add a new `config.<chain>-agents.json` + a target in `workflow.yaml` and
   `project.yaml` for a new network):

   ```json
   {
     "address": "0x<robot-address>",
     "checkData": "0x",
     "name": "<label>"
   }
   ```

2. Make sure a `MailboxCRE` is deployed on that chain and its address is set as `mailboxAddress`.

3. Simulate, then deploy.
