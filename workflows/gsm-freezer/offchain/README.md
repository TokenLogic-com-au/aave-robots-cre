# GSM Freezer — CRE workflow

Off-chain CRE workflow driving [`GsmFreezerReceiver`](../src/GsmFreezerReceiver.sol).
Every 30 seconds (the CRE cron minimum) it calls each receiver's `checkUpkeep` with
empty `checkData`; when a freeze or unfreeze applies it signs the returned `performData`
and writes it back as the receiver's `onReport`. One trigger per GSM receiver
(Ethereum USDC and USDT, Plasma USDT, Monad USDC).

## Config

Each `receiver` is filled in after the matching `GsmFreezerReceiver` is deployed. With
an empty `receiver` that GSM gets no trigger.

## Setup

```bash
cd workflows/gsm-freezer/offchain && npm install   # or `make install` from repo root
```

## Simulate / deploy

```bash
# from workflows/ (the directory with project.yaml)
cre workflow simulate ./gsm-freezer/offchain --env=../.env --target=gsm-freezer-production-settings --non-interactive --trigger-index=0

# --unsigned prints the tx for the owner Safe to propose (does not broadcast)
cre workflow deploy   ./gsm-freezer/offchain --env=../.env --target=gsm-freezer-production-settings --unsigned
cre workflow activate ./gsm-freezer/offchain --env=../.env --target=gsm-freezer-production-settings --unsigned --yes
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
