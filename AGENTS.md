# Keyfleet

Keyfleet runs five founding fleets on Base: the Regents Club, whose keys are
never sold, and Classic, Syndicate, Cascade and Accelerant, whose keys are
bought in USDC. The homepage chooses a fleet, the
fleet page is its map, and a person's keys are on Account; there is no
signed-in Overview. The [README](README.md) describes the product.

- `platform/`: Phoenix/Ash application. Read its instructions for web changes.
- `cli/`: `commands.json`, describing the `regents keyfleet` commands; the code
  that runs them lives in regents-cli.
- `contracts/`: Foundry workspace for the fleet, rewards and votes contracts,
  with their deployment scripts.
- `plugins/`: home for standalone runtime plugin packages; none exist yet.
- There is no `identity/` folder. The shared profile domain comes from
  `regents/identity`, pinned by git in `platform/mix.exs` with `design-system`
  and `elixir-utils`.
- `make check-change` is the check an ordinary change runs before it ships:
  compile with warnings as errors, format, then the tests that cover what
  changed since `origin/main` (`scripts/check-change.sh`). The platform
  README's "Shipping a change" says how a change goes live.
- `make check` runs every gate: the platform's `mix precommit` (which ends
  with the TypeScript typecheck, the unit tests and the browser suite), then the required-fixes check against ash-template
  (needs `gh auth login`), then the CLI's build, typecheck and tests, then the
  contracts' `forge fmt --check`, `forge build` and `forge test`.
  `make check-platform`, `check-required-fixes`, `check-cli` and
  `check-contracts` run one gate. Set `MIX_TEST_PARTITION` (an empty value uses
  `keyfleet_test`).
- `make check-audit-fork` runs the contract audit's proofs on a Base fork pinned
  to one block. It is not part of `make check` and fails without `BASE_RPC_URL`.
- `make readiness` starts the local development server on a free port with the
  error debugger off and checks what the agent-readiness scorer looks for
  (`scripts/readiness.sh`). It needs the local development database.
- `make release` refuses uncommitted changes, runs `make check`, builds HEAD's
  `platform/` and the graph host's sealed Python supply into an image and
  starts it against a throwaway database (`scripts/release.sh`). It never
  deploys; `scripts/deploy.sh production` does.
- Follow the workspace's `regent-workflow`; whoever makes a change ships it.
  Scope verification to observable acceptance and preserve useful
  regression coverage.
- When a step has a clear recommendation, do it; never ask the founder to
  approve it. Ask only for what the platform README's "Shipping a change"
  lists as waiting for the founder's go, or for a choice that changes the goal.
- Preserve uncommitted work and public command/API shapes. Every distinct wallet
  press reaches the wallet. No signing, production access, deployment or
  publishing without applicable founder authority. Never read `.env`,
  `.env.local` or `.envrc`.

The public agent entry point is served at `/llms.txt` from
[platform/priv/public/llms.md](platform/priv/public/llms.md); keep it
consistent with the routes in `platform/lib/keyfleet_web/router.ex` and the
HTTP contract in `platform/contracts/api-contract.openapiv3.yaml`.

## Live checks on keyfleet.ai

Follow regent-workflow's "Live checks". On Keyfleet:

- **CLI.** Sean's Claude Code agent (Key 19) keeps its folder at
  `/Users/sean/keyfleet/claude-code` and its signer at `~/.siwa-agent/claude-code`.
  Check from that folder with `SIWA_AGENT_HOME=~/.siwa-agent/claude-code`:
  `uv run siwa_agent.py request GET https://keyfleet.ai/api/agents/v1/whoami`, and
  `regents keyfleet agents whoami`, `fleets list`, `rooms read`, `workspace get` and
  `workspace changes`. `me` and `rooms sync` write a check-in, so they are agent work,
  not checks. Never read `.env`, `.env.local` or `.envrc` in `/Users/sean/keyfleet` or
  any folder under it; the signer reads what it needs.
- **WebMCP.** Every keyfleet.ai page registers the public reads `about`, `docs`,
  `fleets_list`, `fleets_show`, `workspace_pulse`, `proposals_list` and
  `treasury_show`; signed tools go through `prepare_agent_request` and the SIWA client.
- **Allowlist.** Sean's own Claude settings (`/Users/sean/.claude/settings.json`,
  AGENT-TESTING 1 a, 28 Oct 2026) let a thread run `regents --version`, `regents
  --help` and the `regents keyfleet` groups `account`, `agents`, `code`, `dms`,
  `doctor`, `fleets`, `mutes`, `notebooks`, `polls`, `presence`, `profile`,
  `rooms`, `shards` and `workspace` without asking, and headless Chromium check
  scripts kept in the session's scratchpad. Anything else goes to the auto-mode
  rule "Regent Agent Testing", which leaves out money, credits, wallets, staking,
  claims, `keys claim`, `treasury`, `split`, `proposals carry-out`, secrets and
  acting as another person's Key. Check a release with `regents keyfleet doctor`,
  the reads above and WebMCP in headless Chromium, not with curl requests that
  send data.
- **Connector.** keyfleet.ai/mcp ships switched off
  (`KEYFLEET_CLAUDE_CONNECTOR_ENABLED`). Once it is on and added as a custom connector,
  a Claude thread pairs as harness `claude` with a code from Sean and uses keyfleet.ai
  like any other paired agent: pairing, check-in, and the room, wall, sync, direct
  message, poll, project, workspace, standing, checkpoint, activity and receipt tools
  under the same names (the AgentTools domain's Ash AI `tools` block). The other fleet
  tools join as their actions move onto Ash AI (`docs/agent-parity.md`).

<!-- BEGIN REGENT ROLLOUT REVIEW -->
## Code Review Rules

### Human and agent guidance drift

For every code review, read `.agents/skills/rollout-guidance-check/SKILL.md` and assess the diff's guidance
impact, even when no prose files changed. Trace affected behavior into public docs,
product/developer Skills, human-to-agent prompts, tooltips and other UI copy,
WebMCP/MCP schemas and descriptions, CLI help/errors/examples, OpenAPI, manifests
and generated or bundled copies. Shared behavior starts in ash-template and its
libraries; inspect affected consumers when available.

Report concrete mismatches introduced or made relevant by this change, with the
failing user/agent action and exact source locations. Distinguish source, packaged,
published and deployed versions; name missing cross-repository or live evidence.
Preserve dated history and avoid cosmetic findings. Do not inflate severity or
claim that no findings proves complete coverage. This is read-only review: never
sign, pay, activate earnings, publish or deploy to test an instruction.
<!-- END REGENT ROLLOUT REVIEW -->
