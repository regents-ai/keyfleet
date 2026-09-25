# Keyfleet

The Keyfleet monorepo: a public website with wallet sign-in and a small
account area, a public HTTP API, a command-line tool, and room for contracts
and runtime plugins.

## Components

| Component | What it holds | Check |
| --- | --- | --- |
| [platform/](platform/README.md) | The Phoenix/Ash web application: home page, Privy wallet sign-in, the signed-in Overview and Account pages, public pages, health and metrics, and the served API. | `make check-platform` |
| [cli/](cli/README.md) | A pnpm workspace with one package, `@keyfleet/cli`, publishing the `keyfleet` command. It only prints usage and version today. | `make check-cli` |
| [contracts/](contracts/README.md) | An optional Foundry workspace. Empty until the product needs contracts. | `make check-contracts` |
| [plugins/](plugins/README.md) | Standalone runtime plugin packages. None yet. | None |

## Start

1. Follow the [platform quickstart](platform/README.md#quickstart) to create the
   local database, load Privy credentials and start the server.

2. Build the CLI with `cd cli && pnpm install --frozen-lockfile && pnpm build`.

## Shared dependencies

The platform depends on three sibling repositories resolved through
`REGENT_DEPS_ROOT`: `design-system` (the shared UI), `elixir-utils` (Privy
verification, agent access and lint checks) and `regents/identity` (the shared
profile domain served at `/api/v1/profile`). The
[platform README](platform/README.md#shared-dependencies) explains the layout.

## License

MIT, see [LICENSE](LICENSE). Vendored dependencies retain their own licenses.
