# CapAgent

CRE robot that injects pending [Risk Oracle](https://github.com/ChaosLabsInc/chaos-agents)
updates (supply caps, borrow caps and, where registered, rate strategies) into Aave v3
through the chain's `AgentHub`. Native CRE port of BGD Labs'
[`ChainlinkAgentHub`](https://github.com/ChaosLabsInc/chaos-agents/blob/main/src/contracts/automation/ChainlinkAgentHub.sol)
(`AGENT_HUB_AUTOMATION` in the address book), which runs today as a forwarded robot
behind MailboxCRE on Avalanche, Polygon, Optimism, Arbitrum, Base and BNB.

## Layout

```
cap-agent/
├── src/
│   ├── CapAgentReceiver.sol         # the robot — inherits IAaveCREReceiver, permissionless onReport
│   └── ICapAgentReceiver.sol        # robot interface + minimal AgentHub interface
├── tests/
│   ├── CapAgentReceiver.t.sol       # unit tests (vm.mockCall against the AgentHub)
│   ├── CapAgentReceiver.fork.t.sol  # fork tests: real injections on every covered chain
│   ├── DeployCapAgentReceiver.t.sol # per-chain deploy config vs offchain config
│   └── helpers/
│       ├── CapAgentReceiverHarness.sol
│       └── RiskAgentsInterfaces.sol # AgentHub / Risk Oracle methods used by the fork tests
├── scripts/
│   └── DeployCapAgentReceiver.s.sol # stand-alone forge deploy, one per chain
└── offchain/                        # CRE workflow — see offchain/README.md
```

## On-chain behavior

`CapAgentReceiver` implements [`IAaveCREReceiver`](../shared/src/IAaveCREReceiver.sol):

- `checkUpkeep(_) → (needed, ActionData[])` — read-only probe. Calls
  `AGENT_HUB.check(enabledAgents)`, which returns, per agent, the markets whose latest
  Risk Oracle update is not expired, not injected yet, past the agent's minimum delay and
  valid for the agent. Keeps the first `MAX_ACTIONS` (10) market updates per tick.
  `checkData` is unused: the hub and the agent allowlist are set on the contract.
- `onReport(metadata, ActionData[])` — drops actions for agents not enabled on the robot
  (reverts `NoActionsToExecute` if none is left) and calls `AGENT_HUB.execute(actions)`.
  The hub re-validates every update, also checking the market is configured for the
  agent, and reverts `NoActionCanBePerformed` if nothing is injectable, so a stale report
  fails `estimateGas`.

Ported from `ChainlinkAgentHub`: `checkUpkeep` is the hub's `check` and `performUpkeep` is
the hub's `execute`, with the agent ids moved from the upkeep's `checkData` to an on-chain
allowlist. Added on top: the allowlist filter in `onReport` and the `MAX_ACTIONS` cap. The
hub's own `maxBatchSize` is 0 (unbounded) on every covered chain; the cap keeps a report
well under the CRE write gas quota (two updates cost ~355k gas on Avalanche), and the
remaining updates go out on the next tick.

`onReport` is **permissionless**: `metadata` and `msg.sender` are ignored. It can only
call `execute` on the hub set at deployment, which validates each update itself, and
the agents are not permissioned on the hub (`isAgentPermissioned` is false everywhere),
so anyone can already call `execute` directly. If governance makes an agent permissioned
and adds the receiver as a sender, anyone can still trigger that agent's injections
through the receiver, which only ever injects updates the hub accepts.

### State and access control

- `_enabledAgents` — allowlist of AgentHub agent ids the robot acts on. This is the
  robot's own switch; the hub's `isAgentEnabled` must also be true for injections.
- The initial allowlist is set in the constructor.
- `enableAgent(agentId)` — owner-only. Reverts `InvalidAgent` for an id not registered
  on the hub and `AgentStatusUnchanged` if already enabled.
- `disableAgent(agentId)` — owner or guardian (emergency off-switch). Reverts
  `AgentStatusUnchanged` if not enabled.
- Both emit `AgentStatusUpdated(agentId, enabled)`.
- The contract is `Rescuable`; the owner is the rescue guardian.

## Required permissions

The receiver itself needs no role while the agents stay non-permissioned. For updates to
actually be injected, governance (`EXECUTOR_LVL_1`, which is the hub owner, the agent admin
and the ACL admin on every covered chain) has to restore what is currently switched off.
As of October 2026, on all six chains:

- every agent is disabled on the hub: `AGENT_HUB.setAgentEnabled(agentId, true)`;
- the agent contracts are not risk admins (their injection delegatecalls the config
  engine, so the Pool configurator checks the agent): `ACL_MANAGER.addRiskAdmin(agent)`;
- only if an agent is made permissioned:
  `AGENT_HUB.addPermissionedSender(agentId, receiver)`.

Until then `checkUpkeep` returns false and the workflow does nothing. The legacy
`ChainlinkAgentHub` upkeeps should be cancelled (and removed from the MailboxCRE workflow)
once the receivers are live.

## Configuration

One receiver per chain, pointing at the chain's `AGENT_HUB` from `aave-address-book`
(`Misc<Chain>.AGENT_HUB`, the same hub `AGENT_HUB_AUTOMATION.AGENT_HUB()` returns), with the
agent ids the legacy upkeeps check:

| Chain     | Agents                                      |
| --------- | ------------------------------------------- |
| Avalanche | 0 supply cap, 1 borrow cap, 2 rate strategy |
| Polygon   | 0 supply cap, 1 borrow cap                  |
| Optimism  | 0 supply cap, 1 borrow cap                  |
| Arbitrum  | 0 supply cap, 1 borrow cap, 2 rate strategy |
| Base      | 0 supply cap, 1 borrow cap, 2 rate strategy |
| BNB       | 0 supply cap, 1 borrow cap                  |

## Testing

```bash
# from repo root
forge test --match-path 'workflows/cap-agent/tests/*.t.sol' --no-match-contract 'Fork' -vvv   # unit
forge test --match-contract 'CapAgent.*Fork' -vvv   # fork; needs RPC_AVALANCHE/POLYGON/OPTIMISM/ARBITRUM/BASE/BNB
cd workflows/cap-agent/offchain && bun test                                                   # CRE workflow (bun)
```

The fork suites grant the permissions above by impersonating governance, publish a supply
and a borrow cap update on the live Risk Oracle (impersonating its owner to authorize a
publisher) and check the robot injects both in one report. `CapAgentReceiverForkTest`
also covers, on Avalanche, a stale report, an agent disabled on the robot and a
permissioned agent (rejected until the receiver is added as a permissioned sender).
`CapAgentDeployScriptForkTest` runs the deploy script on each covered chain and checks
the hub matches the legacy `ChainlinkAgentHub`'s.

`workflow.test.ts` runs `createReceiverHandler` against a mocked cre-sdk EVM client
(`EvmMock`) for each branch. Requires `bun` on PATH.

## Deployment

`CapAgentReceiver` deploys stand-alone, one per chain. `DeployCapAgentReceiver` picks the
config from `block.chainid` (reverting on any other chain): the chain's `AGENT_HUB`, its
`GovernanceV3<Chain>.EXECUTOR_LVL_1` / `GOVERNANCE_GUARDIAN` as owner / guardian, and the
agent ids above. `DeployCapAgentReceiver.t.sol` checks the covered chains match
`offchain/config.production.json`.

```bash
# from repo root, with ACCOUNT_NAME=<your-keystore-name> in .env
# env: Avalanche, Polygon, Optimism, Arbitrum, Base or BNB
make deploy-cap-agent env=Avalanche dry=true   # simulate
make deploy-cap-agent env=Avalanche            # broadcast
```

### Post-deploy

1. Set the deployed address as `receiver` for that chain in
   [`offchain/config.production.json`](offchain/config.production.json).
2. Have governance grant the permissions in [Required permissions](#required-permissions).
3. (Re)deploy the CRE workflow through the owner Safe — see
   [`offchain/README.md`](offchain/README.md).

Post-deploy checks (substitute the deployed `<receiver>`):

```bash
cast call <receiver> "owner()(address)" --rpc-url <chain>
cast call <receiver> "guardian()(address)" --rpc-url <chain>
cast call <receiver> "AGENT_HUB()(address)" --rpc-url <chain>
cast call <receiver> "getEnabledAgents()(uint256[])" --rpc-url <chain>
```
