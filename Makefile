-include .env

# Every offchain package (shared + one per robot), so a new robot needs no Makefile or CI change.
OFFCHAIN := $(patsubst workflows/%/offchain/package.json,%,$(wildcard workflows/*/offchain/package.json))

update :; forge update
install :; forge install && npm install && for pkg in $(OFFCHAIN); do npm --prefix workflows/$$pkg/offchain install || exit 1; done

build :; forge build --sizes
test :; forge test -vvv --ffi
test-unit :; forge test --no-match-contract 'Fork' -vvv
test-fork :; forge test --match-contract 'Fork' -vvv --ffi
gas-snapshot :; forge snapshot --match-contract 'FeeSharesMinter'

generate-abis :; npm run generate-abis

# make typecheck-<robot> / test-offchain-<robot> (`shared` for the shared helpers), or `-all`.
typecheck-all :; for pkg in $(OFFCHAIN); do (cd workflows/$$pkg/offchain && npm run typecheck) || exit 1; done
test-offchain-all :; for pkg in $(OFFCHAIN); do (cd workflows/$$pkg/offchain && npm test) || exit 1; done
typecheck-% :; cd workflows/$*/offchain && npm run typecheck
test-offchain-% :; cd workflows/$*/offchain && npm test

# `cast wallet import <name>` first, then set ACCOUNT_NAME in .env.
deploy-account :; forge script ${contract} --rpc-url ${chain} --account ${ACCOUNT_NAME} -vvvv --slow $(if ${dry},,--verify ${verifier} --broadcast)

DEPLOY_CHAIN_Mainnet := mainnet
DEPLOY_CHAIN_Devnet := tenderly_devnet
DEPLOY_CHAIN_Avalanche := avalanche
DEPLOY_CHAIN_Polygon := polygon
DEPLOY_CHAIN_Optimism := optimism
DEPLOY_CHAIN_Arbitrum := arbitrum
DEPLOY_CHAIN_Base := base
DEPLOY_CHAIN_BNB := bnb
DEPLOY_CHAIN_Gnosis := gnosis
DEPLOY_CHAIN_Scroll := scroll
DEPLOY_CHAIN_Plasma := plasma
DEPLOY_CHAIN_Monad := monad
DEPLOY_CHAIN_Ink := ink
DEPLOY_CHAIN_Linea := linea
DEPLOY_CHAIN_Sonic := sonic
DEPLOY_CHAIN_Celo := celo
DEPLOY_CHAIN_ZkSync := zksync
DEPLOY_CHAIN_XLayer := xlayer
DEPLOY_CHAIN_Mantle := mantle
DEPLOY_CHAIN_MegaEth := megaeth

# Tenderly virtual testnets verify against <rpc-url>/verify with a custom verifier;
# other chains use the default Etherscan verifier (foundry.toml [etherscan] + ETHERSCAN_API_KEY).
DEPLOY_VERIFIER_Devnet := --verifier custom --verifier-url $(RPC_TENDERLY_DEVNET)/verify

# Allowed `env`s for a robot whose deploy script doesn't revert on chains it doesn't support.
DEPLOY_ENVS_fee-shares-minter := Mainnet Devnet

# make deploy-<robot> env=<Chain> [dry=1]: runs the robot's only scripts/Deploy*.s.sol, whose
# contract is named after the file.
deploy-% :; @script="$(wildcard workflows/$*/scripts/Deploy*.s.sol)"; \
	[ "$$(echo $$script | wc -w)" -eq 1 ] || { echo "ERROR: expected one workflows/$*/scripts/Deploy*.s.sol"; exit 1; }; \
	[ -n "$(DEPLOY_CHAIN_${env})" ] || { echo "ERROR: unknown env '${env}'"; exit 1; }; \
	case " $(or $(DEPLOY_ENVS_$*),${env}) " in *" ${env} "*) ;; *) echo "ERROR: pass env= one of: $(DEPLOY_ENVS_$*)"; exit 1;; esac; \
	$(MAKE) deploy-account contract=$$script:$$(basename $$script .s.sol) chain=$(DEPLOY_CHAIN_${env}) verifier="$(DEPLOY_VERIFIER_${env})" dry=${dry}
