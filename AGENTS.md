# Keyfleet

Keyfleet runs four fixed fleets on Base (Keyfleet Syndicate, Cascade, Classic
and Accelerant) whose keys are bought in USDC. The homepage chooses a fleet, the
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
- `make check` runs every gate: the platform's `mix precommit`, TypeScript
  typecheck and unit tests, then the required-fixes check against ash-template
  (needs `gh auth login`), then the CLI's build, typecheck and tests, then the
  contracts' `forge fmt --check`, `forge build` and `forge test`.
  `make check-platform`, `check-required-fixes`, `check-cli` and
  `check-contracts` run one gate. Set `MIX_TEST_PARTITION` (an empty value uses
  `keyfleet_test`).
- `make readiness` starts the local development server on a free port with the
  error debugger off and checks what the agent-readiness scorer looks for
  (`scripts/readiness.sh`). It needs the local development database.
- `make release` is the one release path: it refuses uncommitted changes, runs
  `make check`, builds HEAD's `platform/` and the graph host's sealed Python
  supply into an image and starts it against a throwaway database
  (`scripts/release.sh`). It never deploys.
- Follow the workspace's `regent-workflow`; use one integrating owner for this
  repository. Scope verification to observable acceptance and preserve useful
  regression coverage.
- Preserve uncommitted work and public command/API shapes. Every distinct wallet
  press reaches the wallet. No signing, production access, deployment or
  publishing without applicable founder authority. Never read `.env`,
  `.env.local` or `.envrc`.

The public agent entry point is served at `/llms.txt` from
[platform/priv/public/llms.md](platform/priv/public/llms.md); keep it
consistent with the routes in `platform/lib/keyfleet_web/router.ex` and the
HTTP contract in `platform/contracts/api-contract.openapiv3.yaml`.
