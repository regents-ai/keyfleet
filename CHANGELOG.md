# Changelog

This file is append-only. Add new dated entries at the end, in chronological order.
Do not edit, reorder, or remove existing entries; append corrections separately.

## 2026-09-22 — Template cut from Regents

- Cut this template from the Regents monorepo at commit `0bbd67c`.
- Kept the Phoenix/Ash platform with the public home page, Privy wallet sign-in,
  the signed-in Overview and Account pages, the public pages, health and
  metrics, `/llms.txt`, `/openapi.json` and the served API, the design-system
  styling, a pnpm CLI skeleton, an empty optional contracts workspace and an
  empty plugins folder.
- Renamed the placeholder product to Ash Template (`ash_template`, `AshTemplate`,
  `ash-template`, `ASH_TEMPLATE_`).
- Removed everything specific to Regents: staking, Redeem, Autolaunch,
  Formation, Regents Club, ENS, OpenSea, the blog, Regent Names and claims,
  public profiles, agent sign-in, sprites, the Base RPC reads, the Regents CLI
  commands and the Solidity contracts.

## 2026-09-22 — PostgreSQL 17 pin

- Pinned `postgres 17.7` in `platform/.tool-versions`, the server every environment runs.

## 2026-09-22 — Renamed to KeyFleet

- Renamed the Ash Template placeholder to KeyFleet (`keyfleet`, `KeyFleet`,
  `keyfleet`, `KEYFLEET_`) with `scripts/init.sh`, which removed itself.

## 2026-09-22 — mint 1.10.1

- Moved the mint HTTP client to 1.10.1, which closes the medium-severity
  EEF-CVE-2026-82672 (HTTP/1 response smuggling through an unvalidated
  chunk-size line). Lockfile-only change.

## 2026-09-25 — Spelled Keyfleet everywhere

- The product name is spelled Keyfleet in code, copy and documents. The Elixir
  modules are `Keyfleet` and `KeyfleetWeb`, the Mix tasks are `mix keyfleet.*`
  (for example `mix keyfleet.route_handoff`), and pages, titles and legal text
  say Keyfleet. The app name `keyfleet`, the database names and the
  `KEYFLEET_` settings are unchanged. Entries above keep the old spelling.
- Brought over the template's clean-up. `make check` now also runs the CLI and
  contract checks. Unused pictures, fonts, scripts and the old homepage pieces
  are gone, along with the local acceptance setup and reset tasks. The route
  handoff files are now `priv/handoff/route-catalog.*`. Sign-in uses the shared
  Privy session from `elixir-utils`, and its error messages no longer name
  Regent. The World ID row is gone from Account.
- `PRIVY_VERIFICATION_KEY` is read exactly as stored, so it must hold the PEM
  with real line breaks. Escaped `\n` text is no longer turned into line breaks.
- The Terms, Privacy Policy, Contact page and site data now give one contact
  address, build@regents.sh. The Terms title says Keyfleet.

## 2026-09-27 — Fully owned fleets

- Fleets are fully owned by their key holders. Regents takes 2% of each key
  purchase, once, for the Regents staking contract, and nothing from money a
  fleet receives afterwards.
- Income in USDC, REGENT or the fleet's launched token is paid 100% to the keys.
  Everything else is shared money: what is left of key sales, the launched token
  released from vesting, the REGENT held after graduation and any other token.
- A proposal stays open until more than half of all keys sold vote yes, and then
  anyone can carry it out. Keys bought or moved after a proposal opened cannot
  vote on it, and votes can be changed or withdrawn. Every payment is matched:
  every key that did not vote yes can collect the same amount per key.
- A fleet runs one Autolaunch at a time and can propose another after a failed
  one. A key asks for its traits once and can ask again only after a refused
  request.
- Removed referrals, the 2% fee on money a fleet receives, the 20/80 budget
  split, the voting window, the pay cap and period, execution expiries and the
  shared asset registry. The site reads and shows the new rules; its migrations
  need empty payment and proposal tables in production, and `20260927072219`
  cannot be rolled back.
- The shared Regent libraries (`elixir-utils`, `design-system` and `regents`)
  are pinned by git to one commit each in `platform/mix.exs`. `make check` also
  runs `make check-required-fixes`, which fetches ash-template's list of
  required fixes and its checker from GitHub, runs it against the platform, and
  needs `gh auth login`.

## 2026-09-27 — Pages carry a content security policy

- Every page now carries one of the template's three content security policies,
  from `KeyfleetWeb.ContentSecurityPolicy`: the pages with the account button
  allow what Privy's wallet sign-in loads; the public documents, the fleet
  directory's Markdown and the "not open yet" answers get the strict reading
  policy; the local showcase may frame its own preview. Keyfleet's pages load
  nothing from another site beyond Privy's sign-in, so no origin was added.
- A browser check loads the home, fleet, proposals, key and Account pages, the
  closed page and the start of sign-in, and fails on any refusal. Privy's window
  itself was not opened here: this machine has no Privy app to sign in to.
- The ignore line for Regent UI images is gone; nothing produces them.

## 2026-09-27 — One release path, checked end to end

- `make release` refuses uncommitted changes, runs `make check`, builds HEAD's
  `platform/` with the graph host's sealed Python supply into an image, through
  `platform/scripts/build-release-context.sh`, and starts it against a throwaway
  PostgreSQL: the staging release commands, the health endpoint, a built
  stylesheet, the graph host's Python and the server's database connection. It
  prints the app commit, the shared-library commits, the graph host supply and
  the image digest. It never deploys.

## 2026-09-27 — Short addresses from regent_format

- Every shortened address now comes from the shared `regent_format` library,
  pinned by git to the same `elixir-utils` commit as the other shared
  libraries, exactly as ash-template does it. Addresses read `0x1234..abcd`
  (two full stops) on every page, in the activity lines, the wallet panel and
  the fleet directory's JSON, whose contract pattern changed to match.
- A sent transaction's hash is shortened as a hash, `0x12345678…abcdef`, not as
  an address.
- `KeyfleetWeb.FleetLive.short_wallet/1` is gone; no page shortens an address
  by itself.

## 2026-09-27 — How long ago, from regent_format

- An agent's "last check-in" and "last contribution" times on the fleet page's
  "Who's here" panel and the key page now come from the shared
  `RegentFormat.relative_time/2`. Up to a week they read as before ("just
  now", "3 minutes ago", "2 days ago"); past that they read in weeks, months
  (thirty days) and years ("2 weeks ago", "3 months ago") instead of days.
- `KeyfleetWeb.Time.ago/2` is gone; `KeyfleetWeb.Time` keeps `moment/2`.

## 2026-09-27 — Autolaunch v2 is the launch target

- `docs/autolaunch-target.md` now pins Autolaunch v2, the Revstake package on
  the Autolaunch branch `feat/contracts-v2` at `da2519b`. It is a candidate:
  not pushed, not deployed on Base, no addresses yet. The code keeps building
  against the deployed v1 factory until v2 is deployed and the founder says to
  switch.
- The document records v2's call (a floor price and an optional higher minimum
  instead of a required raise), its events and views, the fixed terms (20%
  sold, 15% pooled, 65% vesting over 365 days, a 48-hour auction), graduation
  and the bids' share-out, how each of Keyfleet's gaps resolves, what Keyfleet
  changes to adopt v2, and six open questions. No code, contract or test
  changed.

## 2026-09-28 — Phase 1 close-out

- A sold-out fleet keeps its Buy button on the page, disabled, with "144/144
  keys sold" beside it and a line saying a key can still be had from someone
  who holds one. It is the one wallet button a page ever disables.
- The unused session lease is gone; session authority matches Regents'.
- `/healthz` reads the database and answers 503 when it can't.
- `scripts/release.sh` removes the throwaway database's volume when it cleans
  up.
- Every page's title and description come from one registry in
  `KeyfleetWeb.PublicDocuments`; titles end in "· Keyfleet", the homepage's
  reads "Keyfleet" alone.
- The Privacy Policy and Terms of Use are public documents like `/about`,
  outside the launch gate, with Markdown twins. Reading pages send no
  referrer. `/developers` is gone.
- The app shell has a "Skip to content" link, and after moving to another
  page the focus goes to that page's heading.
- Every page offers a browser's own agent two read tools, `about` and `docs`,
  from `priv/tool_manifest.json`; `/capabilities` serves the manifest, `/docs`
  and `/llms.txt` list the tools, and every answer carries
  `permissions-policy: tools=(self)`.
- A count that the database refuses no longer crashes a page: the fleet page
  says it couldn't count the agents, the homepage says which read failed and
  keeps what it had, and the fleet directory answers 503 and says so.
- Raw SQL names the schema from `Keyfleet.Repo.default_prefix/0`.
- Tests prove a stale copy can't approve a pairing, or move the graph cursor
  on, a second time.
- `KEYFLEET_APP_SURFACES` takes exactly `on` or `off`; anything else stops the
  boot, and production must set it. Development and test set it in their own
  config.
- The release tests call `bootstrap_staging` and `pending_migrations`
  themselves; the `_for_test` variants are gone.

## 2026-09-28 — elixir-utils 28f6ebc: rate limits and one error shape

- elixir-utils moves from `7a876e8` to `28f6ebc` (`regent_agent_access` 0.2.0).
- Every `/healthz` and `/api` answer, including an unknown `/api` address and a
  signed agent request refused before the router, carries the `RateLimit-Policy`
  and `RateLimit` headers for one budget per client address, 120 requests a
  minute. Past it the answer is 429 with `Retry-After` and the code
  `too_many_requests`. Pages and sign-in are not counted.
- An error that is not a route's own refusal is
  `{"error": {"code", "message", "hint"}}`; `/docs` lists it as a breaking
  change and `openapi.json` moves to 2.0.0.
- `openapi.json` gives every operation a 429 with the rate-limit headers and a
  default error answer, and every other answer the rate-limit headers. The
  YAML contract declares the 429 on every `/api` operation.

## 2026-09-28 — Every JSON error in one shape

- Every JSON error Keyfleet gives is `{"error": {"code", "message", "hint"}}`,
  with one plain message and hint per code in `KeyfleetWeb.Refusal`. That
  covers the directory, the metadata, the launch gate, browser sign-in and every
  signed agent request. A route's own refusal was `{"error": "code"}` and keeps
  its code.
- A workspace refusal carries its `details` inside `error`, beside the
  workspace's own message.
- The closed site's answer is the code `not_open_yet` and the directory's
  unreadable answer the code `directory_unavailable`; both were sentences.
- The profile answers come from the Regents identity library and keep
  `{"error": {"code"}}` until that library changes.
- The YAML contract, `openapi.json`, `/docs`, `/skill.md`, `/llms.txt` and the
  tests describe and check only this shape.

## 2026-09-28 — Sent steps read through the site's own node

- `Keyfleet.ChainClient`, from the template at `97df7c9`, reads what a page's
  wallet sent through the site's own node for the chain (`:chain_nodes`), never
  the public address a wallet adds the chain with. `KEYFLEET_RPC_URL` sets
  Base's node in development and production, so a press on a Base-fork lab
  shows done; unset, Base's public node is read.
- `Keyfleet.Chain.Client` and `Keyfleet.Chain.RpcClient` serve the fleet reader
  alone; they no longer read transactions or receipts.
- A chain request that gets no answer is counted in
  `keyfleet.chain.failure.total`.
- Tests land sent steps on `Keyfleet.TestChainNode`, a local node the suite and
  the browser test server start; a lab anvil is the node for its own chain.
