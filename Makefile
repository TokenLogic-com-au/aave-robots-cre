-include .env

# This repo is offchain-only: generic CRE automation workflows that connect CRE
# to the existing Aave robots via MailboxCRE. No Solidity lives here.

install :; npm install && cd workflows/automation && bun install

lint :; npm run lint
lint-fix :; npm run lint:fix

# Simulate one network's workflow against mainnet (interactive trigger picker).
# Usage: make simulate chain=ethereum
#   chain ∈ {ethereum, polygon, optimism, arbitrum, base, bnb, avalanche}
simulate :; cd workflows && cre workflow simulate ./automation --target=$(chain)-agents-production-settings

# Simulate a single robot non-interactively (trigger order = config "automations" order).
# Usage: make simulate-one chain=ethereum i=0
simulate-one :; cd workflows && cre workflow simulate ./automation --target=$(chain)-agents-production-settings --non-interactive --trigger-index=$(i)

# Deploy / activate via the owner Safe — `--unsigned` prints the tx to propose.
# Usage: make deploy chain=ethereum   /   make activate chain=ethereum
deploy :; cd workflows && cre workflow deploy ./automation --target=$(chain)-agents-production-settings --unsigned
activate :; cd workflows && cre workflow activate ./automation --target=$(chain)-agents-production-settings --unsigned --yes
