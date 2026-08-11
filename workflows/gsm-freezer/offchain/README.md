# GSM Freezer — CRE workflow

Off-chain CRE workflow driving [`GsmFreezerReceiver`](../src/GsmFreezerReceiver.sol).
On each cron tick it calls a receiver's `checkUpkeep`; when a freeze/unfreeze is
warranted it signs the returned `performData` and writes it back as the receiver's
`onReport`. The receiver holds the GSM and bounds as immutables and re-derives the
action itself, so the workflow performs no off-chain reads and passes empty
`checkData`. One trigger per GSM receiver (Ethereum: USDC + USDT).

## Files

| File                     | Purpose                                                             |
| ------------------------ | ------------------------------------------------------------------- |
| `main.ts`                | Entry point — builds the runner from `config.production.json`.      |
| `workflow.ts`            | `initWorkflow` (one handler per receiver) + `createReceiverHandler`. |
| `types.ts`               | Zod config schema (`schedule`, `evms[].receiver`).                  |
| `config.production.json` | Per-GSM receiver (Ethereum USDC + USDT).                            |
| `workflow.test.ts`       | `bun test` unit suite (mocked cre-sdk EVM client).                  |

Each `receiver` is filled in after the corresponding `GsmFreezerReceiver` is
deployed on Ethereum.

## Setup

```bash
cd workflows/gsm-freezer/offchain && npm install   # or `make install` from repo root
```

## Simulate / deploy

```bash
# from workflows/ (the directory with project.yaml)
cre workflow simulate ./gsm-freezer/offchain --target=gsm-freezer-production-settings --non-interactive --trigger-index=0

# --unsigned prints the tx for the owner Safe to propose (does not broadcast)
cre workflow deploy   ./gsm-freezer/offchain --target=gsm-freezer-production-settings --unsigned
cre workflow activate ./gsm-freezer/offchain --target=gsm-freezer-production-settings --unsigned --yes
```

Or via the `package.json` scripts (`npm run simulate:production`,
`npm run deploy:production:unsigned`, …). The workflow name is set in
[`workflow.yaml`](workflow.yaml) (`gsm-freezer-production`). Deploying again with the
same name updates the existing workflow.

## Testing

```bash
npm run typecheck   # tsc --noEmit (needs shared/offchain deps installed)
bun test            # workflow.test.ts
```
