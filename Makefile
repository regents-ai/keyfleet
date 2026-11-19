.DEFAULT_GOAL := help
.PHONY: help check check-change check-platform platform-assets platform-checks check-required-fixes check-cli check-siwa-latest check-contracts check-notebook-hub release
help:
	@echo "Run make check-change before an ordinary change ships: it compiles with warnings as errors, checks the format, and runs the contracts' gate when contracts/ changed since origin/main."
	@echo "Run make check for every gate, side by side, each writing its output to platform/_build/check/<gate>.log; it prints every gate's log, the failed ones last, then one line per gate."
	@echo "Or run check-platform, check-required-fixes, check-cli, check-siwa-latest or check-contracts for one component."
	@echo "Run make check-notebook-hub for the fleet notebook hub; it is not part of make check and must succeed before any hub image is pushed."
	@echo "Run make release to run every gate, then build the committed tree into an image and start it against a throwaway database."
# make check builds the platform's assets, then runs its gates side by side, each
# writing its output to $(CHECK_LOGS)/<gate>.log, then prints every gate's log,
# the failed ones last, and one line per gate, and fails when any gate failed.
# The assets are built before any other gate starts: the platform's typecheck
# reads the shared libraries' scripts and tokens they copy. The contracts run
# under nice: the Solidity compiler takes every core it can, and gives way.
CHECK_FIRST := platform-assets
CHECK_LANES := platform-checks check-required-fixes check-cli check-siwa-latest check-contracts
CHECK_GATES := $(CHECK_FIRST) $(CHECK_LANES)
CHECK_LOGS := platform/_build/check
# Each gate's budget in seconds, about 40% over its time in make check on a
# 16-core Mac (Nov 2026), and 5 s for a gate that takes a second or two. The
# assets' budget holds the compile a change brings (25 s after a changelog
# entry, which the site serves), and the required fixes' the three answers it
# waits for from GitHub (2 to 7 s). A gate over its budget gets a SLOW line
# under its own at the end; it never fails the check.
CHECK_BUDGETS := platform-assets:35 platform-checks:10 check-required-fixes:10 check-cli:5 \
  check-siwa-latest:5 check-contracts:11
check:
	@mkdir -p $(CHECK_LOGS) && : > $(CHECK_LOGS)/results
	@echo "Running $(words $(CHECK_GATES)) gates, $(CHECK_FIRST) first, then the rest side by side; each writes $(CHECK_LOGS)/<gate>.log."
	@run() { \
	  start=$$(date +%s); \
	  $(MAKE) --no-print-directory $$1 > $(CHECK_LOGS)/$$1.log 2>&1; \
	  code=$$?; echo "$$1 $$code $$(( $$(date +%s) - start ))" >> $(CHECK_LOGS)/results; \
	}; \
	run $(CHECK_FIRST); \
	for gate in $(CHECK_LANES); do run $$gate & done; wait
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
	  budget=$$(printf '%s\n' $(CHECK_BUDGETS) | sed -n "s/^$$gate://p"); \
	  if [ "$$3" -gt "$$budget" ]; then echo "SLOW: $$gate took $$3 s (budget $$budget s)"; fi; \
	done; \
	test -z "$$failed"
# The check an ordinary change runs before it ships (scripts/check-change.sh).
# BASE=<ref> compares with another starting point than origin/main.
check-change:
	scripts/check-change.sh
# The platform's whole gate, in turn (mix precommit in platform/mix.exs); make
# check runs its parts below.
check-platform:
	cd platform && mix precommit
platform-assets:
	cd platform && mix assets.build
platform-checks:
	cd platform && mix precommit.checks
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
REGENTS_CLI_REV := c12d8563c46e8b5229e32db76c1a104fb469b7b7
check-cli:
	uv run --no-project scripts/check_command_docs.py
	uv run --no-project --with "regents-cli[check] @ git+https://github.com/regents-ai/regents-cli@$(REGENTS_CLI_REV)" \
	  python -m regents_cli.check_commands cli/commands.json platform/priv/public/openapi.json platform/priv/static/api-contract.openapiv3.yaml
# Fails until the pins name the newest regents-cli release and the SIWA library
# as it is on elixir-utils main (scripts/check-siwa-latest.sh). Needs `gh auth login`.
check-siwa-latest:
	scripts/check-siwa-latest.sh $(REGENTS_CLI_REV)
check-contracts:
	cd contracts && nice forge fmt --check && nice forge build && nice script/check_bytecode.sh
# The fleet notebook hub: compute-fly's types, lint and bundle in the pinned
# marimohub workspace, and the hub and runner images. Needs Node 24 and Docker. It
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
