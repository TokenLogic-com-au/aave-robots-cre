# CapAgent

CRE robot that injects pending [Risk Oracle](https://github.com/ChaosLabsInc/chaos-agents)
updates (supply caps, borrow caps, rate strategies) into Aave v3 through each chain's
`AgentHub`. Native CRE port of BGD's
[`ChainlinkAgentHub`](https://github.com/ChaosLabsInc/chaos-agents/blob/main/src/contracts/automation/ChainlinkAgentHub.sol),
on Avalanche, Polygon, Optimism, Arbitrum, Base and BNB.

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

- `checkUpkeep(_) → (needed, ActionData[])` — read-only probe. Calls `AGENT_HUB.check`
  for each enabled agent `execute` would act on (a permissioned agent only if this receiver
  is one of its permissioned senders), skipping an agent whose `check` reverts (e.g. a
  malformed Risk Oracle value), and keeps the first `MAX_ACTIONS` (10) market updates per
  tick, since the hub's `maxBatchSize` is unset. `checkData` is unused.
- `onReport(metadata, ActionData[])` — drops actions for agents not enabled on the robot
  (reverts `NoActionsToExecute` if none is left) and calls `AGENT_HUB.execute` once per
  market update, so a failing injection only emits `ActionFailed(agentId, market, reason)`
  (reason capped at `MAX_REASON_LENGTH`, 256 bytes). The hub re-validates each update
  (expiry, update id, minimum delay, agent validation, configured market); `onReport`
  reverts `NoActionCanBePerformed` if none was injected.

`onReport` is **permissionless**: `metadata` and `msg.sender` are ignored. No agent is
permissioned on the hubs, so anyone can already call `execute` directly. Adding the receiver
as a permissioned sender of an agent makes that agent effectively permissionless: anyone can
trigger its valid injections through `onReport`, as with BGD's `performUpkeep`.

### State and access control

- `_enabledAgents` — allowlist of hub agent ids the robot acts on, set in the constructor.
  Independent of the hub's own `isAgentEnabled`, which must also be true.
- `enableAgent(agentId)` — owner-only. Reverts `InvalidAgent` for an id not registered on
  the hub and `AgentStatusUnchanged` if already enabled.
- `disableAgent(agentId)` — owner or guardian (emergency off-switch). Reverts
  `AgentStatusUnchanged` if not enabled.
- Both emit `AgentStatusUpdated(agentId, enabled)`.
- The contract is `Rescuable`; the owner is the rescue guardian.

## Governance prerequisites

The receiver needs no role, but on every covered chain the agents are disabled on the hub
and the agent contracts don't hold `RISK_ADMIN` (their injection delegatecalls the config
engine). Before anything is injected, `EXECUTOR_LVL_1` (hub owner, agent admin and ACL
admin) must call `AGENT_HUB.setAgentEnabled(agentId, true)` and
`ACL_MANAGER.addRiskAdmin(agent)` for each agent, plus
`AGENT_HUB.addPermissionedSender(agentId, receiver)` for a permissioned agent.

## Configuration

One receiver per chain on `Misc<Chain>.AGENT_HUB` from `aave-address-book`, with the agents
the current upkeeps check: 0 (supply cap) and 1 (borrow cap) everywhere, plus 2 (rate
strategy) on Avalanche, Arbitrum and Base.

## Testing

```bash
# from repo root
forge test --match-path 'workflows/cap-agent/tests/*.t.sol' --no-match-contract 'Fork' -vvv   # unit
forge test --match-contract 'CapAgent.*Fork' -vvv   # fork; needs RPC_AVALANCHE/POLYGON/OPTIMISM/ARBITRUM/BASE/BNB
cd workflows/cap-agent/offchain && bun test                                                   # CRE workflow (bun)
```

The fork suites grant the prerequisites above by impersonating governance, publish a
supply and a borrow cap update on the live Risk Oracle and check the robot injects both in
one report. `CapAgentReceiverForkTest` also covers, on Avalanche, a stale report, an agent
disabled on the robot, a permissioned agent, an agent without `RISK_ADMIN` next to one with
it, and a malformed (33-byte) update; `CapAgentDeployScriptForkTest` runs the deploy script
on every covered chain.

`workflow.test.ts` runs `createReceiverHandler` against a mocked cre-sdk EVM client
(`EvmMock`) for each branch. Requires `bun` on PATH.

## Deployment

`DeployCapAgentReceiver` picks the config from `block.chainid` and reverts on any other
chain: the chain's `AGENT_HUB`, its `GovernanceV3<Chain>.EXECUTOR_LVL_1` /
`GOVERNANCE_GUARDIAN` as owner / guardian, and the agents above.

```bash
# from repo root, with ACCOUNT_NAME=<your-keystore-name> in .env
# env: Avalanche, Polygon, Optimism, Arbitrum, Base or BNB
make deploy-cap-agent env=Avalanche dry=true   # simulate
make deploy-cap-agent env=Avalanche            # broadcast
```

### Post-deploy

1. Set the deployed address as `receiver` for that chain in
   [`offchain/config.production.json`](offchain/config.production.json).
2. Have governance grant the [prerequisites](#governance-prerequisites).
3. (Re)deploy the CRE workflow through the owner Safe — see
   [`offchain/README.md`](offchain/README.md).

```bash
cast call <receiver> "AGENT_HUB()(address)" --rpc-url <chain>
cast call <receiver> "getEnabledAgents()(uint256[])" --rpc-url <chain>
```
