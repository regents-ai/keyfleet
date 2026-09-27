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
