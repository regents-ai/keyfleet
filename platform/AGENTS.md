# Keyfleet platform

This is the Phoenix/Ash component of the Keyfleet monorepo. Run Mix and npm
here. `lib/keyfleet/` owns domains; `lib/keyfleet_web/` owns routes and
live pages. `contracts/` holds the OpenAPI contract, synced to `priv/static/`
with `mix keyfleet.sync_api_contract`.

Follow the root instructions and the workspace's `regent-workflow`. Use the
assignment's acceptance and applicable focused checks. Browser fixtures belong to
the prepared local database. Shared dependencies (`design-system/regent_ui`,
`elixir-utils/privy`, `elixir-utils/agent_access`, `elixir-utils/siwa`,
`elixir-utils/credo_ash`, `regents/identity`) are git pins in `mix.exs`.

Every page's content security policy lives in
`lib/keyfleet_web/content_security_policy.ex`; add an exact origin to the one
profile that needs it, never a wildcard or `'unsafe-eval'`. Rate limits key
on `KeyfleetWeb.ClientAddress`, and metrics are served only on the private
port. The README's "Security profiles" section explains all three.
