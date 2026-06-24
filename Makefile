-include .env

update :; forge update
install :; forge install && npm install && npm --prefix workflows/shared/offchain install && npm --prefix workflows/fee-shares-minter/offchain install && (cd workflows/automation && bun install)

lint :; npm run lint
lint-fix :; npm run lint:fix

build :; forge build --sizes
test :; forge test -vvv --ffi
test-unit :; forge test --no-match-contract 'Fork' -vvv
test-fork :; forge test --match-contract 'Fork' -vvv --ffi
gas-snapshot :; forge snapshot --match-contract 'FeeSharesMinter'

generate-abis :; npm run generate-abis

typecheck-fee-shares-minter :; cd workflows/fee-shares-minter/offchain && npm run typecheck
test-offchain-fee-shares-minter :; cd workflows/fee-shares-minter/offchain && npm test

# `cast wallet import <name>` first, then set ACCOUNT_NAME in .env.
deploy-account :; forge script ${contract} --rpc-url ${chain} --account ${ACCOUNT_NAME} -vvvv --slow $(if ${dry},,--verify ${verifier} --broadcast)

DEPLOY_CHAIN_Mainnet := mainnet
DEPLOY_CHAIN_Devnet := tenderly_devnet

# Tenderly virtual testnets verify against <rpc-url>/verify with a custom verifier;
# mainnet uses the default Etherscan verifier (foundry.toml [etherscan] + ETHERSCAN_API_KEY).
DEPLOY_VERIFIER_Devnet := --verifier custom --verifier-url $(RPC_TENDERLY_DEVNET)/verify

deploy-fee-shares-minter :; @[ -n "$(DEPLOY_CHAIN_${env})" ] || { echo "ERROR: pass 'env=Mainnet' or 'env=Devnet'"; exit 1; }; \
	make deploy-account contract=workflows/fee-shares-minter/scripts/DeployFeeSharesMinter.s.sol:DeployFeeSharesMinter chain=$(DEPLOY_CHAIN_${env}) verifier="$(DEPLOY_VERIFIER_${env})" dry=${dry}

# ==========================================================================
# Automation workflows (existing protocol robots via MailboxCRE) - see
# workflows/automation. chain in {ethereum,polygon,optimism,arbitrum,base,bnb,avalanche}
# ==========================================================================

# Simulate one network's workflow against mainnet (interactive trigger picker).
# Usage: make simulate chain=ethereum
simulate :; cd workflows && cre workflow simulate ./automation --target=$(chain)-agents-production-settings

# Simulate a single robot non-interactively (trigger order = config "automations" order).
# Usage: make simulate-one chain=ethereum i=0
simulate-one :; cd workflows && cre workflow simulate ./automation --target=$(chain)-agents-production-settings --non-interactive --trigger-index=$(i)

# Deploy / activate via the owner Safe - `--unsigned` prints the tx to propose.
# Usage: make deploy-automation chain=ethereum   /   make activate-automation chain=ethereum
deploy-automation :; cd workflows && cre workflow deploy ./automation --target=$(chain)-agents-production-settings --unsigned
activate-automation :; cd workflows && cre workflow activate ./automation --target=$(chain)-agents-production-settings --unsigned --yes
