# Local acceptance database

This foundation creates one disposable PostgreSQL database on this machine. It uses only `127.0.0.1`, the PostgreSQL role matching the current user, and a database named `keyfleet_acceptance_<run_id>`. Choose a new lowercase run ID for every run.

The supported tools are the Erlang, Elixir, Node and PostgreSQL versions pinned in `.tool-versions`, plus Playwright at the version in `package.json`. The checkout also requires the sibling `elixir-utils` checkout at the commit named at the top of `bin/setup-local-acceptance`, because the locked Privy dependency is loaded from `../elixir-utils/privy`.

From a clean checkout, setup is one command:

```sh
bin/setup-local-acceptance founder_local_001
```

The setup checks the sibling dependency commit, local tools, and remote deployment or database settings before creating anything. It fetches locked backend dependencies, invokes the guarded setup task, installs locked browser packages, creates the unique database, runs the checked-in migrations, and builds the browser assets. It does not load `.env`, `.env.local`, or `.envrc`. The lower-level `MIX_ENV=test mix key_fleet.setup_local --run-id <run-id>` command is for debugging only.

Always remove the run database when finished. Running reset again is safe:

```sh
bin/reset-local-acceptance founder_local_001
bin/reset-local-acceptance founder_local_001
```

Reset verifies the immutable run, database, and local-role ownership marker before deleting only that run database. It also removes generated browser assets. If the target, marker, environment, host, role or name is unexpected, the command stops without deleting anything.
