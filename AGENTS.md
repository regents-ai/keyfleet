# Keyfleet

- `platform/`: Phoenix/Ash application. Read its instructions for web changes.
- `cli/`: pnpm workspace for the `keyfleet` command. Only `help` and
  `version` exist.
- `contracts/`: optional Foundry workspace, empty until contracts are needed.
- `plugins/`: home for standalone runtime plugin packages; none exist yet.
- There is no `identity/` folder. The shared profile domain comes from the
  sibling `regents/identity` package, resolved through `REGENT_DEPS_ROOT` with
  `design-system` and `elixir-utils`. Use `REGENT_DEPS_ROOT` for isolated builds.
- Run checks from the owning component or use the root Make targets.
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
