.DEFAULT_GOAL := help
.PHONY: help check check-change check-platform platform-assets platform-checks platform-suite platform-walks check-required-fixes check-cli check-siwa-latest check-contracts check-audit-fork check-notebook-hub release readiness
help:
	@echo "Run make check-change before an ordinary change ships: it runs the tests that cover what changed since origin/main."
	@echo "Run make check for every gate, side by side, each writing its output to platform/_build/check/<gate>.log; it prints every gate's log, the failed ones last, then one line per gate."
	@echo "Or run check-platform, check-required-fixes, check-cli, check-siwa-latest or check-contracts for one component."
	@echo "Run make check-notebook-hub for the fleet notebook hub; it is not part of make check and must succeed before any hub image is pushed."
	@echo "Run make release to run every gate, then build the committed tree into an image and start it against a throwaway database."
	@echo "Run make readiness to start the local server and check what the agent-readiness scorer looks for."
# make check builds the platform's assets, then runs its gates side by side, each
# writing its output to $(CHECK_LOGS)/<gate>.log, then prints every gate's log,
# the failed ones last, and one line per gate, and fails when any gate failed.
# The gates of one quoted lane run in turn. The assets are built before any lane
# starts and never again while they run: the browser walks serve them, and the
# ExUnit suite's pages read priv/esbuild-meta.json, which esbuild rewrites in
# place. The walks come after the other checks in their lane, and each walk's
# server has a database of its own, so the suite runs beside them. The contracts
# run under nice: the Solidity compiler takes every core it can, and gives way.
CHECK_FIRST := platform-assets
CHECK_LANES := "platform-checks platform-walks" platform-suite check-required-fixes check-cli check-siwa-latest check-contracts
CHECK_GATES := $(CHECK_FIRST) $(subst ",,$(CHECK_LANES))
CHECK_LOGS := platform/_build/check
check:
	@mkdir -p $(CHECK_LOGS) && : > $(CHECK_LOGS)/results
	@echo "Running $(words $(CHECK_GATES)) gates, $(CHECK_FIRST) first, then the rest side by side; each writes $(CHECK_LOGS)/<gate>.log."
	@run() { \
	  start=$$(date +%s); \
	  $(MAKE) --no-print-directory $$1 > $(CHECK_LOGS)/$$1.log 2>&1; \
	  code=$$?; echo "$$1 $$code $$(( $$(date +%s) - start ))" >> $(CHECK_LOGS)/results; \
	}; \
	run $(CHECK_FIRST); \
	for lane in $(CHECK_LANES); do \
	  for gate in $$lane; do run $$gate; done & \
	done; wait
	@failed=; \
	for gate in $(CHECK_GATES); do \
	  if grep -q "^$$gate 0 " $(CHECK_LOGS)/results; then \
	    echo; echo "== $$gate ($(CHECK_LOGS)/$$gate.log)"; cat $(CHECK_LOGS)/$$gate.log; \
	  else failed="$$failed $$gate"; fi; \
	done; \
	for gate in $$failed; do \
	  echo; echo "== $$gate FAILED ($(CHECK_LOGS)/$$gate.log)"; cat $(CHECK_LOGS)/$$gate.log; \
	done; \
	echo; \
	for gate in $(CHECK_GATES); do \
	  set -- $$(grep "^$$gate " $(CHECK_LOGS)/results); \
	  if [ "$$2" = 0 ]; then echo "$$gate: ok in $$3 s"; else echo "$$gate: FAILED after $$3 s"; fi; \
	done; \
	test -z "$$failed"
# The check an ordinary change runs before it ships (scripts/check-change.sh).
# BASE=<ref> compares with another starting point than origin/main.
check-change:
	scripts/check-change.sh
# The platform's whole gate, in turn (mix precommit in platform/mix.exs); make
# check runs its parts below side by side.
check-platform:
	cd platform && mix precommit
platform-assets:
	cd platform && MIX_ENV=test mix assets.build
platform-checks:
	cd platform && mix precommit.checks
platform-suite:
	cd platform && mix precommit.suite
platform-walks:
	cd platform && mix precommit.walks
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
REGENTS_CLI_REV := 4a781568f763e2f7c1165684c4d8d8e2341ce0ee
check-cli:
	uv run --no-project scripts/check_command_docs.py
	uv run --no-project --with "regents-cli[check] @ git+https://github.com/regents-ai/regents-cli@$(REGENTS_CLI_REV)" \
	  python -m regents_cli.check_commands cli/commands.json platform/priv/public/openapi.json platform/priv/static/api-contract.openapiv3.yaml
# Fails until the pins name the newest regents-cli release and SIWA library change
# (scripts/check-siwa-latest.sh). Needs `gh auth login`.
check-siwa-latest:
	scripts/check-siwa-latest.sh $(REGENTS_CLI_REV)
check-contracts:
	cd contracts && nice forge fmt --check && nice forge build && nice forge test --no-match-path 'test/audit/KeyfleetAuditFork.t.sol' && nice script/check_bytecode.sh
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
