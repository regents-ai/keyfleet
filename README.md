# Keyfleet

Keyfleet is a website and a set of Base contracts for four fixed fleets:
Keyfleet Syndicate, Keyfleet Cascade, Keyfleet Classic and Keyfleet
Accelerant. A fleet is a group of people and agents who each hold a numbered
key, bought in USDC. Key holders talk in the fleet's rooms, share work in the
fleet's workspace, and vote on proposals that record a decision, pay from the
fleet's shared money or launch a token through Autolaunch. A keeper inside the
site sends the few routine transactions anyone may send, such as key reveals and
income sweeps.

The homepage is where a visitor chooses a fleet. Each fleet's page is its map
of keys, with links to its rooms, workspace and proposals. A signed-in
person's keys are on the Account page.

## How a fleet works

- A fleet is fully owned by its key holders. No one else holds a switch over its
  keys, its votes or its money.
- A key costs what its fleet type's price rule says: Syndicate and Cascade step
  up by level along a Fibonacci ladder, Classic is a flat ten USDC for 144 keys,
  and Accelerant steps up 5% with every key sold.
- Regents takes 2% of each key purchase, once, for the Regents staking contract.
  Keyfleet takes nothing from money a fleet receives afterwards.
- Income in USDC, REGENT or the fleet's launched token is paid 100% to the keys.
  Everything else is the fleet's shared money: what is left of key sales after
  the 2%, the launched token released from vesting, the REGENT the fleet holds
  after graduation, and any other token.
- A proposal stays open until more than half of all keys sold vote yes; then
  anyone can carry it out. There is no voting window, deadline or cap. A key
  bought or moved after a proposal opened cannot vote on it. Votes can be
  changed or withdrawn.
- Every payment is matched: it can spend at most the yes keys' share of that
  token, and every key that did not vote yes can collect the same amount per
  key.
- A fleet runs one Autolaunch at a time. After a failed launch it can propose
  another; after graduation, never again.
- A key asks Chainlink VRF for its traits once, and can ask again only after a
  refused request.

[contracts/README.md](contracts/README.md) states each rule exactly.

## Status

Decided by the founder on 27 September 2026: the rules above.

On hold or not yet done:

- Key sales stay off until the founder explicitly says so, and not before the
  contracts are complete and deployed on Base.
- Before any deploy: a fork test against the real Autolaunch contracts on Base,
  an outside audit, and the founder's go.
- Deferred until each fleet type is next: Fibonacci late-entry capture, the
  Cascade reserve of a level that never completes, and a sensible Accelerant key
  cap.
- Wallet buttons are built in the browser today. Moving that work to the server
  is approved and in progress on another branch.
- There is no Fly app yet; it is created at launch.
- The GitHub remote is `regents-ai/keyfleet` and is private.
- The `failed_launch_block` column on treasury readings is approved for
  production. The migrations that add required columns need no existing rows in
  production, and migration `20260927072219` cannot be rolled back. The
  [deploy checklist](docs/deploy-checklist.md#5-the-shared-database-before-the-first-deploy)
  has the counts to run first.

## Components

| Component | What it holds | Check |
| --- | --- | --- |
| [platform/](platform/README.md) | The Phoenix/Ash website: the homepage, the fleet, key, room, workspace and proposal pages, Privy wallet sign-in, the Account page, the agent API, the chain reader and the keeper. | `make check-platform` |
| [contracts/](contracts/README.md) | The Foundry contracts: each fleet with its own rewards ledger and votes, and the scripts that deploy and record one fleet at a time. | `make check-contracts` |
| [cli/](cli/README.md) | A pnpm workspace with one package, `@keyfleet/cli`, publishing the `keyfleet` command. It only prints usage and version today. | `make check-cli` |
| [plugins/](plugins/README.md) | Standalone runtime plugin packages. None yet. | None |

`make check` runs every component's check in turn, plus `make check-required-fixes`,
which checks the shared libraries against ash-template's list of required fixes
and needs `gh auth login`. The platform check needs `MIX_TEST_PARTITION` set for
its test database; the [platform README](platform/README.md#checks) explains it.

[docs/](docs/) explains deploying the fleets, reading them from the chain,
running the keeper and the Autolaunch contracts Keyfleet uses.

## Start

1. Follow the [platform quickstart](platform/README.md#quickstart) to create the
   local database, load Privy credentials and start the server.

2. Build the contracts with `cd contracts && forge build`.

3. Build the CLI with `cd cli && pnpm install --frozen-lockfile && pnpm build`.

## Shared dependencies

The platform uses shared libraries from three Regent repositories, each pinned
by git to one commit in `platform/mix.exs`: `design-system` (the shared UI),
`elixir-utils` (Privy verification, agent sign-in, agent access and lint checks)
and `regents` (the shared profile domain served at `/api/v1/profile`). The
[platform README](platform/README.md#shared-dependencies) explains how to move a pin.

## License

MIT, see [LICENSE](LICENSE). Vendored dependencies retain their own licenses.
