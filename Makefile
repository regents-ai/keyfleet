.DEFAULT_GOAL := help
.PHONY: help check check-change check-platform check-required-fixes check-cli check-siwa-latest check-contracts check-audit-fork check-notebook-hub release readiness
help:
	@echo "Run make check-change before an ordinary change ships: it runs the tests that cover what changed since origin/main."
	@echo "Run make check for every gate, or check-platform, check-required-fixes, check-cli, check-siwa-latest or check-contracts for one component."
	@echo "Run make check-notebook-hub for the fleet notebook hub; it is not part of make check and must succeed before any hub image is pushed."
	@echo "Run make release to run every gate, then build the committed tree into an image and start it against a throwaway database."
	@echo "Run make readiness to start the local server and check what the agent-readiness scorer looks for."
check: check-platform check-required-fixes check-cli check-siwa-latest check-contracts
# The check an ordinary change runs before it ships (scripts/check-change.sh).
# BASE=<ref> compares with another starting point than origin/main.
check-change:
	scripts/check-change.sh
check-platform:
	cd platform && mix precommit
# Every site runs the same check against ash-template's current main branch, so a
# newly published required fix reaches every site's next gate. Needs `gh auth login`.
TEMPLATE := repos/regents-ai/ash-template
check-required-fixes:
	cd platform && mkdir -p _build && rev=$$(gh api $(TEMPLATE)/commits/main --jq .sha) \
	&& gh api -H "Accept: application/vnd.github.raw" "$(TEMPLATE)/contents/platform/scripts/check_required_fixes.exs?ref=$$rev" > _build/check_required_fixes.exs \
	&& gh api -H "Accept: application/vnd.github.raw" "$(TEMPLATE)/contents/security/required-fixes.json?ref=$$rev" > _build/required-fixes.json \
	&& elixir _build/check_required_fixes.exs "ash-template $$rev" < _build/required-fixes.json
# The command description check is regents-cli's own checker at the commit pinned
# here, run by uv straight from GitHub. Move the pin in a commit.
REGENTS_CLI_REV := 8c29aff897fedc11ea8db4ee088f6926a32a8836
check-cli:
	uv run --no-project scripts/check_command_docs.py
	uv run --no-project --with "regents-cli[check] @ git+https://github.com/regents-ai/regents-cli@$(REGENTS_CLI_REV)" \
	  python -m regents_cli.check_commands cli/commands.json platform/priv/public/openapi.json platform/priv/static/api-contract.openapiv3.yaml
# Fails until the pins name the newest regents-cli release and SIWA library change
# (scripts/check-siwa-latest.sh). Needs `gh auth login`.
check-siwa-latest:
	scripts/check-siwa-latest.sh $(REGENTS_CLI_REV)
check-contracts:
	cd contracts && forge fmt --check && forge build && forge test --no-match-path 'test/audit/KeyfleetAuditFork.t.sol' && script/check_bytecode.sh
# The audit's proofs against real Base contracts, on a fork pinned to one block.
# Needs BASE_RPC_URL and fails without it.
check-audit-fork:
	cd contracts && forge test --match-path 'test/audit/KeyfleetAuditFork.t.sol' -vv
# The fleet notebook hub: compute-fly in the pinned marimohub workspace, the hub
# and runner images, and the runner helper's tests. Needs Node 24 and Docker. It
# is not part of make check because it builds a 3 GB image; run it before any hub
# image is pushed.
check-notebook-hub:
	notebook-hub/scripts/check.sh
# The release checks and builds exactly the committed tree, so every change must
# be committed first. A failing gate stops it before anything is built.
release:
	@test -z "$$(git status --porcelain)" || { echo "Commit every change first: the release checks and builds the committed tree." >&2; exit 1; }
	$(MAKE) check
	scripts/release.sh
# Starts the local server on a free port, checks what the agent-readiness scorer
# looks for against it, and stops it. Needs the local development database.
readiness:
	scripts/readiness.sh
