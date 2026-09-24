# Aave Depositor — CRE workflow

Off-chain CRE workflow driving [`AaveDepositorReceiver`](../src/AaveDepositorReceiver.sol).
On each cron tick it reads every active V3 reserve, prices, caps and Collector balances,
builds one Steward call per eligible token (`depositV3`, and `migrateV2toV3` on chains
with a V2 pool), asks the receiver's `checkUpkeep` to validate the batch, then signs it
and writes it back as the receiver's `onReport`. One workflow instance per chain.

## Files

| File / folder          | Purpose                                                                 |
| ---------------------- | ----------------------------------------------------------------------- |
| `main.ts`              | Entry point — builds the runner from the chain config.                  |
| `workflow.ts`          | `initWorkflow` (one cron handler) + `onCronTrigger` + `submitCalls`.    |
| `types.ts`             | Zod config schema (single chain, flat).                                 |
| `helpers/`             | `reserves` + `caps` (batched reads), `deposits` + `migrations` (candidates), `steward` (call encoding), `multicall`, `reads`, `config`, `math`. |
| `abi/`                 | Vendored ABIs for the Aave data providers, oracle, Steward, Multicall3. |
| `config.ethereum.json` | Ethereum mainnet config. `receiver` is filled in after deploy.          |
| `workflow.test.ts`     | `bun test` unit suite (mocked cre-sdk EVM client).                      |

Addresses are normalized on parse, so casing in the JSON does not matter. Numeric
fields are decimal strings (USD amounts have 8 decimals).

## Config

| Field                             | Meaning                                                        |
| --------------------------------- | -------------------------------------------------------------- |
| `receiver`                        | Deployed `AaveDepositorReceiver` on this chain                 |
| `dataProviderV3`, `priceOracle`   | Aave V3 protocol data provider and oracle                      |
| `collector`                       | Source of the idle funds                                       |
| `corePoolV3`, `primePoolV3`       | Destination pools; `primeTokens` are routed to the prime pool  |
| `dataProviderV2`, `corePoolV2`    | Optional; enable V2 to V3 migrations                           |
| `depositMinUsd`, `migrationMinUsd`| Skip tokens below this USD value                               |
| `migrationBps`                    | Fraction (bps) of the V2 balance to migrate per run            |
| `ignoredTokens`                   | Never touched                                                  |

## Chain reads

CRE allows 15 chain reads per execution (`ChainRead.CallLimit`), so reads are packed into
Multicall3 batches: reserves, prices, configs, Collector balances, V2 aTokens, V2
balances + liquidity, caps + aTokens, aToken supplies (8), then one read of the
receiver's forwarder and pinned workflow id, then `checkUpkeep` and `estimateGas` per
report batch (2 each). The workflow therefore writes at most 3 report batches per run
(`MAX_REPORTS_PER_RUN`) and logs how many calls it deferred to the next tick.

## Gas

The receiver only accepts reports from the CRE forwarder, so the workflow reads
`FORWARDER()` and `expectedWorkflowId()` from the receiver and estimates `onReport`
as the forwarder would call it. A revert (role not granted, bad selector) skips the
write with a log instead of a failed transaction. The write is sent with the estimate
plus 25% headroom (a migration through Roles + Safe + Steward costs ~750k, a deposit
~300k on a mainnet fork) and calls are batched at most 8 per report so a batch stays
well under the 10M gas the DON allows per transaction; a batch over that is skipped.

## Setup

```bash
cd workflows/aave-depositor/offchain && npm install   # or `make install` from repo root
```

## Simulate / deploy

```bash
# from workflows/ (the directory with project.yaml)
cre workflow simulate ./aave-depositor/offchain --target=aave-depositor-ethereum-production-settings --non-interactive --trigger-index=0

# --unsigned prints the tx for the owner Safe to propose (does not broadcast)
cre workflow deploy   ./aave-depositor/offchain --target=aave-depositor-ethereum-production-settings --unsigned
cre workflow activate ./aave-depositor/offchain --target=aave-depositor-ethereum-production-settings --unsigned --yes
```

After the workflow is deployed, pin it on the receiver with
`setExpectedWorkflowId(<workflow id>)` (owner only).

## Test

```bash
cd workflows/aave-depositor/offchain && bun test && npm run typecheck
```
