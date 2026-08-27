# Governance Storage Roots — CRE workflow

Submits Ethereum storage proofs to the `DataWarehouse` on each voting chain
whenever an Aave Governance V3 proposal's voting is activated, so cross-chain
voting power can be proven. This is the CRE port of
[`bgd-labs/aave-governance-v3-robot` → `cre/gov-storage-roots`](https://github.com/bgd-labs/aave-governance-v3-robot/tree/main/cre/gov-storage-roots).

It is **not** part of the generic `automation` engine (that only does
`checkUpkeep → forward`): root submission needs off-chain `eth_getProof`, so it
is its own log-triggered workflow.

## Architecture

```
CRE workflow (log trigger: VotingActivated on Governance V3, Ethereum)
  └─ getProposal(proposalId)                  # read votingPortal from governance
       └─ resolveVotingNetwork(votingPortal)  # map portal → voting chain + DataWarehouse + Mailbox
            └─ eth_getBlockByHash(snapshot)   # header via ConfidentialHTTPClient
            └─ eth_getProof(AAVE, aAAVE, stkAAVE, Governance)
                 └─ processStorageRoot × 4     # account proofs
                 └─ processStorageSlot × 1     # stkAAVE exchange-rate slot (0x51)
                      └─ via MailboxCRE.onReport()  (writeReport / signed report)
```

The `eth_getProof` requirement is why the generic EVM read capability is not
enough: proofs are fetched through CRE's `ConfidentialHTTPClient` against an
external Ethereum RPC (held as the `ETH_RPC_URL` secret). `viem`'s `toRlp` /
`fromRlp` build the block-header RLP (Pectra-aware, up to 21 fields) and re-wrap
the proof node arrays.

## Files

| File                     | Purpose                                                                    |
| ------------------------ | ------------------------------------------------------------------------- |
| `main.ts`                | Entry point — `Runner.newRunner` + `createHandlers`.                       |
| `handlers.ts`            | Log trigger on `VotingActivated`; one handler.                            |
| `processStorageRoots.ts` | Core flow — read proposal, fetch proofs, submit via `MailboxCRE`.          |
| `proofs.ts`              | `prepareBlockRLP` (header RLP) + `formatToProofRLP` (proof node re-wrap).  |
| `rpc.ts`                 | `eth_getBlockByHash` / `eth_getProof` over `ConfidentialHTTPClient`.       |
| `types.ts`               | Zod config schema (`ethereumChainSelectorName`, `tokens`, `votingNetworks`). |
| `config.production.json` | Mainnet governance + token + voting-network (eth/avax/polygon) addresses. |
| `config.staging.json`    | Sepolia placeholder for testing.                                           |
| `workflow.test.ts`       | `bun test` — header RLP hashes back to a real block hash; proof round-trip. |

ABIs live in [`../contracts/abi`](../contracts/abi) (`IGovernanceCore`,
`IDataWarehouse`, `IMailboxCRE`).

## Secrets

`ETH_RPC_URL` (namespace `main`) — Ethereum RPC for `eth_getBlockByHash` and
`eth_getProof`. Declared in [`../secrets.yaml`](../secrets.yaml). For local
simulation, export it first:

```bash
export ETH_RPC_URL="https://eth.llamarpc.com"
```

## Setup

```bash
cd workflows/gov-storage-roots && bun install
```

## Simulate / deploy

Run from `workflows/` (the directory with `project.yaml`):

```bash
cre workflow simulate ./gov-storage-roots --target=gov-roots-production-settings
cre workflow deploy   ./gov-storage-roots --target=gov-roots-production-settings --unsigned
cre workflow activate ./gov-storage-roots --target=gov-roots-production-settings --unsigned --yes
```

## Testing

```bash
npm run typecheck   # tsc --noEmit
bun test            # workflow.test.ts
```
