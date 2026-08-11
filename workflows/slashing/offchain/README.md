# Slashing — CRE workflow

Off-chain CRE workflow driving [`SlashingReceiver`](../src/SlashingReceiver.sol).
On each cron tick it calls the receiver's `checkUpkeep`; when a reserve needs
slashing it signs the returned `performData` and writes it back as the receiver's
`onReport`. The receiver holds the Umbrella as an immutable and enumerates the
stake tokens itself, so the workflow performs no off-chain reads and passes empty
`checkData`.

## Files

| File                     | Purpose                                                             |
| ------------------------ | ------------------------------------------------------------------- |
| `main.ts`                | Entry point — builds the runner from `config.production.json`.      |
| `workflow.ts`            | `initWorkflow` (one handler per network) + `createReceiverHandler`. |
| `types.ts`               | Zod config schema (`schedule`, `evms[].receiver`).                  |
| `config.production.json` | Per-chain receiver (Ethereum only).                                 |
| `workflow.test.ts`       | `bun test` unit suite (mocked cre-sdk EVM client).                  |

`receiver` is filled in after the `SlashingReceiver` is deployed on Ethereum.

## Setup

```bash
cd workflows/slashing/offchain && npm install   # or `make install` from repo root
```

## Simulate / deploy

```bash
# from workflows/ (the directory with project.yaml)
cre workflow simulate ./slashing/offchain --target=slashing-production-settings --non-interactive --trigger-index=0

# --unsigned prints the tx for the owner Safe to propose (does not broadcast)
cre workflow deploy   ./slashing/offchain --target=slashing-production-settings --unsigned
cre workflow activate ./slashing/offchain --target=slashing-production-settings --unsigned --yes
```

Or via the `package.json` scripts (`npm run simulate:production`,
`npm run deploy:production:unsigned`, …). The workflow name is set in
[`workflow.yaml`](workflow.yaml) (`slashing-production`). Deploying again with the
same name updates the existing workflow.

## Testing

```bash
npm run typecheck   # tsc --noEmit (needs shared/offchain deps installed)
bun test            # workflow.test.ts
```
