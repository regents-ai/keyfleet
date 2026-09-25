.DEFAULT_GOAL := help
.PHONY: help check check-platform check-cli check-contracts
help:
	@echo "Run make check for every gate, or check-platform, check-cli or check-contracts for one component."
check: check-platform check-cli check-contracts
check-platform:
	cd platform && mix precommit && npm run typecheck && npm test
check-cli:
	cd cli && pnpm build && pnpm typecheck && pnpm test
check-contracts:
	cd contracts && forge fmt --check && forge build && forge test
