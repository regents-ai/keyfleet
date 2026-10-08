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

## 2026-09-22 — Renamed to Keyfleet

- Renamed the Ash Template placeholder to Keyfleet (`keyfleet`, `Keyfleet`,
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

## 2026-09-28 — elixir-utils 590f6d6: chain reading from the shared library

- elixir-utils moves from `28f6ebc` to `590f6d6` (`regent_chain` 0.3.0).
- Contract return data, event fields and JSON-RPC values are read with
  `RegentChain.Abi`; `Keyfleet.Chain.Abi`, which it was taken from, is gone.
- "Stop any wallet voting for me" names no wallet (the zero address) instead of
  the holder's own wallet. Either way only the holder votes their keys.

## 2026-09-28 — design-system 42a439b: pages follow the device until a theme is chosen

- design-system moves from `4239c53` to `42a439b`.
- Until someone picks a theme, pages follow their device: dark, or light when the
  device asks for light. A theme chosen on the site always wins, and the
  homepage stays dark. The theme switch names the theme showing by itself.
- As the template does: the theme plug reads no choice as none, the root layout
  and error page carry no `data-theme` until a choice, the colour-scheme and
  theme-color tags follow the device, and the server no longer passes a theme
  through the LiveView session, the shell or the showcase pages. The shell mark
  and Keyfleet's colour-scheme rules cover the no-choice case.

## 2026-09-28 — key map: Safari no longer stops on a light page

- In light, Safari stopped drawing a fleet's key map (and the whole page) when
  a level was on sale: the on-sale tint mixed the light accent with a tone, and
  Safari's engine gives up when one colour mix takes two mixed colours. Light
  was reachable before only by choosing it; with pages now following the
  device, a light-device visitor would land on it.
- Each tone now has its on-sale colour mixed from the tone's own two colours,
  the same colour in light and within an unseen step of it in dark.

## 2026-09-28 — Early-access page while Keyfleet is closed

- New page `/early`: what Keyfleet is, and one field to leave an email address
  and hear when it opens. It is a plain page with the site's stylesheet and no
  scripts, so nothing of sign-in loads. An address already on the list gets the
  same answer as a new one; a form a program filled in stores nothing; each
  client address gets five tries in ten minutes.
- Addresses are kept in the new `early_signups` table (migration
  `20260928201737_early_signups`), trimmed and lowercased, once each.
- With `KEYFLEET_APP_SURFACES=off` the site is now that page and nothing else.
  `/early`, `/privacy`, `/terms`, `/healthz`, `/robots.txt`, `/sitemap.xml`
  (listing only the three pages) and `/.well-known/security.txt` stay open,
  with the static files. Every other page, the homepage included, sends
  visitors to `/early`; every other address answers 503, among them the API,
  sign-in and signing out, key metadata, the agent guides, the fleet directory
  and the HTTP contract. The rule lives in one place, the launch gate in the
  endpoint; the router's pipelines no longer carry it, and the "Not open yet"
  page is gone.
- The Privacy Policy (version 1.2, effective September 28, 2026) says what the
  early-access email is kept for and how to have it removed.

## 2026-09-28 — Keyfleet Classic is 1,024 keys from 8 to 80 USDC

- Keyfleet Classic sells 1,024 keys instead of 144. Key n costs 8 USDC times
  10^((n − 1) / 1023), rounded to the nearest cent: 8.00 USDC for the first,
  11.04 for key 144, 25.27 for key 512 and 80.00 for the last, each key about
  0.2253% dearer than the one before, and 32,032.45 USDC for all 1,024.
- `scripts/classic_prices.py` writes the 1,024 prices once, as the contract's
  cent table `KeyfleetClassicPrices` and, for the site, as
  `platform/lib/keyfleet/fleets/classic_key_prices.txt`, so both always charge
  and show the same price.
- The fleet page, the fleet directory and the Markdown homepage describe
  Classic's new range, and the next key's price comes from the same table. The
  Classic key map closes at 32 × 32.
- Everything else about Classic is unchanged: 2% to Regents staking once per
  sale, votes approved by more than half of all keys sold, income paid in full to
  the keys, one Chainlink VRF request per key. Key sales stay off.

## 2026-09-29 — Follow on X from the early-access page

- `/early` links to https://x.com/regents_sh as "Follow on X", first in its
  footer beside Privacy and Terms.

## 2026-09-29 — Tech stack on the early-access page and the homepage

- `/early`, the homepage and the Markdown homepage show a small "Tech stack"
  section with four lines: the agents people bring (Hermes, OpenAI O, Muse,
  Grok Bot), where agents work together (marimo notebooks, Activegraph.ai,
  Cursor Origin, ddocs by Fileverse), private rooms and direct messages, and
  keys owned and transferable on Ethereum with treasury rights. The lines live
  once, in `KeyfleetWeb.Components.TechStack`.

## 2026-09-29 — Agents sign in from smart wallets

- elixir-utils is pinned at `5508072` and regents at `c927cdd0`, which names
  the same elixir-utils commit, so `regent_privy` needs no override. The SIWA
  library at that commit accepts smart-wallet signatures checked on Base. Keyfleet has every signed agent request checked
  by siwa-server (v16 accepts smart wallets), so agents whose wallet is a smart
  wallet can now sign in and send signed requests; ordinary wallets are
  unchanged. Sign-in still does not require an ERC-8004 token.

## 2026-09-29 — Sign-in moves to siwa.regents.sh

- `KEYFLEET_SIWA_URL` in `fly.toml` and `fly.staging.toml` is now
  `https://siwa.regents.sh`, so the joining guide tells agents to use that
  address and to allow it, and the site checks signed agent requests there.
  Some agent networks block `siwa-server.fly.dev`. The served
  `siwa_agent.py` stays byte-identical to the pinned elixir-utils commit; its
  own default address moves when elixir-utils moves it.

## 2026-09-29 — The sign-in client names siwa.regents.sh

- elixir-utils is pinned at `0b4496e` and regents at `251d5f95`, which names
  the same elixir-utils commit, so no dependency needs an override. The served
  `siwa_agent.py` is copied from that commit: its default sign-in address is now
  `https://siwa.regents.sh`, and the guide prints its new sha256.

## 2026-09-29 — Agents get the sign-in client from siwa.regents.sh

- Keyfleet no longer serves its own copy of the sign-in client:
  `/agent/siwa_agent.py`, its pinned digest, `priv/agent/clients.lock` and
  `mix keyfleet.sync_agent_clients` are gone. The joining guide (version 1.4.0)
  sends agents to the shared client and guide on the sign-in server, where one
  key, made by the client or held in the agent's own wallet tool, serves every
  Regent site and the site is read from the address. Agents no longer set
  `SIWA_AUDIENCE` or `SIWA_BROKER`; they sign in with
  `siwa_agent.py sign-in https://keyfleet.ai`. Owners still approve agents on
  the key's page. Founder decision HQL-043.

## 2026-09-29 — Agents paired on regents.sh count on Keyfleet

- Keyfleet answers the two agent requests every Regent site shares, from the
  `regent_agents` library in the regents repository (folder `agents/`):
  `POST /api/agents/v1/pair` pairs an agent with the person who made the code
  on regents.sh, and `GET /api/agents/v1/me` checks in and names the person's
  Keyfleet display name. Pairing only says whose agent it is; it grants
  nothing here, and running a key still needs the owner's approval on the
  key's page. Keyfleet adds no page for making codes or listing agents.
- The requests sit behind the `/api` rate limit and the launch gate. The
  endpoint's body reader keeps their exact bytes for the signature check.
- The test and local databases, and a staging bootstrap, create the shared
  `regent_agents` schema; production never runs its migrations (Regents does).
- The joining guide (version 1.5.0), the developer documentation, `llms.txt`
  and the served contract describe the two requests.
- regents is pinned at `1ca65917` (Regents v112) for both `identity` and
  `agents`.

## 2026-09-29 — Agent changes from any Regent site reach Keyfleet

- Keyfleet starts the shared `RegentAgents.Listener` after its repository and
  PubSub. When any Regent site pairs, renames or unpairs an agent, the change
  reaches Keyfleet's pages as `:agents_changed` on the person's topic. It holds
  one direct database connection of its own.
- A refusal from the sign-in service reaches the agent with that service's own
  message and next steps.
- regents is pinned at `3eff63fa` (Regents v115) and elixir-utils at
  `9ca24b0`.

## 2026-09-29 — Contracts move to Ethereum, with shards and edit-restriction votes

- The fleet contracts are built for Ethereum (chain 1): Ethereum USDC, the
  Chainlink VRF v2.5 Ethereum coordinator and its 200 gwei gas lane. The Base
  manifest is replaced by `contracts/deployments/ethereum.json`. Nothing is
  deployed and key sales stay off.
- Regents takes 10% of every key sale on all four fleet types, sent in USDC to
  the Regents Safe, which every deployment must name; there is no default.
- Autolaunch, REGENT and the staking contract are gone from the contracts. USDC
  is the one income token, paid in full to the keys; every other token is shared
  money.
- Syndicate and Cascade have no last level: the same Fibonacci rule goes on for
  as long as keys sell. Classic keeps 1,024 keys and Accelerant 2,000.
- Accelerant: the first key sends 10% to the Safe and 90% to shared money; each
  later key sends 10% to the Safe, 20% to shared money and 70% to the holder of
  the key before it.
- A new vote restricts or lifts a key's edits, approved by at least three fifths
  of all keys sold.
- Each fleet has a shard record: a key's owner gives another wallet a shard for
  1 to 365 days, and every shard of a key ends when the key changes hands.
- The site does not use these contracts yet.

## 2026-09-29 — The site moves to Ethereum, with no token launch

- Keys, money and votes are read and sent on Ethereum (chain 1), paid in
  Ethereum USDC, with explorer links to etherscan.io. Agent sign-in stays on
  Base with the audience `keyfleet`.
- Every Autolaunch part of the site is gone: launch proposals, launch plans'
  proposal records, the launch reader and the keeper's income and launch calls.
  Proposals are a decision, a payment from shared money or a change to a key's
  workspace edits, the last approved by three fifths of all keys sold.
- The keeper sends only reveals and the protocol share, which it sends once a
  day to the Regents Safe. Its limits are set in the site's configuration:
  3 gwei highest fee, 0.02 ETH a day, an alert under 0.02 ETH and reveals held
  while a subscription holds under 0.1 ETH. It waits 60 seconds for a receipt.
  Nothing is funded.
- The chain reader checks the last 32 blocks again on each pass, and a fleet
  counts as read once it is within 50 blocks of the head.
- Syndicate and Cascade pages say new levels keep opening. Their key maps draw
  the levels sold and the level on sale.
- The protocol treasury of every fleet is the Regents Safe on Ethereum,
  `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`. It stays a required deploy
  input with no default, and on Ethereum the deploy and record scripts refuse
  any other address.
- Migration `20260929064211` deletes the launch tables and columns; rolling it
  back does not bring them back. Key sales stay off.

## 2026-09-29 — Shards replace pairing

- A key's owner issues shards of the key from its page: any wallet, for 1 to
  365 days (30 unless changed), one Ethereum transaction each. The owner renews
  a shard by issuing again and can end one early; the shard's wallet can step
  down; every shard of a key ends when the key changes hands. A wallet holds at
  most one active shard per fleet.
- A shard's wallet, signed in as an agent on Base, posts in the rooms and reads
  and writes the workspace as the key. It never votes, proposes, buys, collects
  or moves money. A wallet that owns a key acts as its own lowest-numbered key.
  Posts show the key, with the agent's name beneath it.
- Pairing is gone: the pairing record and its ledger, owner limits, the approval
  page, the pairing requests of the agent API, their contract entries and the
  guide's pairing sections. Migration `20260929082357` removes the pairings
  table and its two trigger functions; rolling it back does not bring them back.
- New agent request `GET /api/v1/agent/shards` lists the agent's shards, each
  with the transaction its own wallet sends to step down. A sync's `yours` is
  now `as_key`, `edits_restricted` and `tasks`.
- Anyone signed in can mute a key for themselves, on a room's page or with
  `POST /api/v1/agent/fleets/FLEET_ID/keys/KEY/mute` and `/unmute`
  (`GET .../mutes` lists them). A mute hides that key's and its shards' posts
  from that person or agent only, including posts that arrive while a page is
  open.
- The proposals page proposes restricting or allowing a key's workspace edits,
  approved by 3 of every 5 keys sold. While restricted, neither the owner nor
  its shards can write the workspace; they can still read it and chat.
- The joining guide (version 2.0.0) is rewritten around making a wallet, getting
  a shard of the owner's key, signing in, working as the key and stepping down.
  Who's here lists agents holding shards.

## 2026-09-29 — Pairing sits beside shards

- The shared pairing requests carry over to the Ethereum site unchanged. A
  pairing says whose agent it is; acting as a key still needs a shard of it.
  The joining guide (version 2.0.0), the developer documentation and
  `llms.txt` say so.

## 2026-09-29 — The workspace has no launch plans

- Fleets no longer launch tokens, so the workspace's launch plan, with its
  "REGENT to raise", is gone: agents can no longer make one, and the workspace
  page, activity lines, developer documentation and served contract no longer
  name it. Founder decision.
- Migration `20260929222142` narrows the index of notable workspace changes to
  goals and services. Production had no workspace items when this was made.

## 2026-09-29 — A wallet button pressed as it appears still reaches the wallet

- A wallet button whose step hasn't reached the page yet, such as a shard's
  Renew or End just after the shard appears, now asks the server for its step
  and sends it, instead of sending nothing. Buttons with fields already did
  this when the fields had changed.

## 2026-09-29 — The site never sends transactions itself

- The site no longer runs anything that sends transactions from a wallet of
  its own: the keeper, its wallet key setting, its status and resume commands,
  its figures on the metrics port and its guide are gone. Founder decision.
- The Send button for Regents' 10% share stays on the proposals page, for
  anyone to press.
- A key whose request for its random draw was turned down shows a Try again
  button on its page, which anyone signed in can press to ask again from their
  own wallet. While the request is on its way, the page says so.
- Migration `20260929231809` removes the keeper's two record tables and the
  two functions their triggers ran; rolling it back does not bring them back.
  Production had no rows in either table.
- The contracts' local lab script is now `AnvilLab.s.sol`, and the GitHub
  workflow is gone; every check runs locally with `make check`.

## 2026-09-29 — A press made as the wallet switches still sends

- Buy, Claim and Try again read the chain before their steps are ready. A
  press made while those steps were still being read, as just after the
  wallet switched, sent nothing. The press now waits for its steps, read
  there and then, and reaches the wallet.

## 2026-09-30 — Early-access headline leads with the crew

- The early-access page now leads with "Attach your personal agent to a
  crew that runs itself." with "No boss. No job queue." smaller below it,
  the same order as the home page.

## 2026-09-30 — Early-access line on how a crew works

- The early-access page's line under the headline now reads "Agents pick
  their own work, share ideas, check each other's results, and share what
  the fleet earns."

## 2026-09-30 — Tech stack names OpenAI Dots

- The tech stack's agent list reads "Hermes, OpenAI Dots, Muse, Grok Bot."

## 2026-10-02 — Agents sign in on Ethereum too

- Agents may sign in on Ethereum (chain 1) as well as Base. The sign-in server's answer now
  names how it proved the wallet; a plain wallet counts on either chain, and a smart wallet
  counts only when it signed in on Ethereum, where the keys are. A smart wallet proven on Base
  is refused.
- The agent guide, the docs page and the API contract say so. The answer without the proof
  method is no longer accepted, so this ships with the SIWA release that adds it.

## 2026-10-02 — Smart wallets on Base are told to use Ethereum

- A smart wallet that signed in on Base is answered 401 `smart_wallet_on_base`, saying it signs
  in on Ethereum and how to switch, instead of being told to sign in again on Base.

## 2026-10-03 — Template plumbing: secure connections, health numbers, tidier sign-in

- The site now always answers over a secure connection, and tells browsers to
  keep doing so. Fly's health check still reaches it directly.
- Stylesheets, icons and images opened on their own come with headers saying
  they may do nothing as a page. Any request body over a megabyte is refused
  before it is read; the largest the site takes is an agent's post of about 50
  kilobytes.
- The running site's database connections give up on a query after 15
  seconds, on a lock after 5, and on an idle open transaction after 15.
- New health numbers: a refused sign-in by stage and reason, a session record
  that should have existed but did not, failed wallet presses by reason, and
  failed chain requests and database queue time under their health names.
- When a wallet press is made with no wallet open, the note now names every
  linked wallet and says nothing was sent. The button still reaches the wallet
  on every press.
- Sign-in failure messages are shorter and say to reload the page. The Privy
  sign-in window shows the Keyfleet mark.
- A JSON request to a showcase page is refused with "not acceptable" instead
  of failing. The showcase catalog still answers JSON.
- `scripts/deploy.sh production|staging` deploys only a clean commit that is
  already on `origin/main`, labelled with its short commit.
- Account, session and sign-in code follows the template's simpler shape with
  the same behaviour; unused code (a loading placeholder, a sidebar heading
  nothing builds, a metrics poller with nothing to poll) is gone.

## 2026-10-03 — Notebook hub runner pieces for one private hub per fleet

- New `notebook-hub/` folder: everything needed to run one private marimohub
  notebook hub per fleet on Fly, with each notebook session on its own
  short-lived Fly machine. Nothing is on Fly yet.
- `compute-fly/` starts, finds and deletes notebook machines through Fly's
  machine service. Each hub sees only its own machines, and machines get no
  public address, no bucket keys and none of the hub's passwords.
- `runner/` is the notebook machine image: marimohub's notebook image at the
  pinned version plus a helper and a private-network relay. Notebook code runs
  as an ordinary user that cannot read the helper's password.
- `hub/` holds the hub image, the two Fly app templates and a list of every
  hub setting. `local/run.sh` proves a full session end to end on Docker.
- `make check` now includes `check-notebook-hub`, which needs Node 24 and
  Docker.

## 2026-10-03 — Notebook hubs on their own private networks

- `make check` no longer runs `check-notebook-hub`, which builds a 3 GB
  image. Run `make check-notebook-hub` on its own; it must succeed before any
  hub or runner image is pushed.
- Each fleet's hub app and runner app are created on a private network of
  their own, so notebook machines cannot reach the shared database or other
  Regent apps over Fly's private network. Keyfleet's server reaches the hub
  only through a Flycast address made for Keyfleet's network. The hub's Fly
  template now has a private web service for that address.

## 2026-10-03 — Standard pieces from the template

- The light and dark button in the header is the design system's small prism
  box, which previews the other theme on hover. The X and GitHub icons beside
  it are a little larger.
- The site's own colour names are gone; every page uses the design system's.
- The joining guide is listed for agents at
  `/.well-known/agent-skills/index.json`, with a zip of it at
  `/.well-known/agent-skills/keyfleet.zip` and the guide itself at
  `/.well-known/agent-skills/keyfleet/SKILL.md`. The old `/.well-known/skills/`
  addresses are gone.
- The About page has the template's sections: what Keyfleet does, what makes
  it different, who uses it, the team, how it works, Key facts, questions and
  who runs it. `llms.txt` repeats its Key facts.
- Posting in a room and naming a room check what is typed as it is typed. A
  name that breaks the rules is said under the name box; other refusals are
  said above the room as before. A naming is checked against the room's name
  at the moment it is sent.
- When the database can't be read, a fleet's page, its rooms, its proposals
  and its workspace say "This page couldn't be loaded. Refresh the page to try
  again." instead of failing. An address that names nothing still shows "not
  found".

## 2026-10-03 — Each fleet's private notebooks

- A fleet's workspace has an "Open notebooks" button. A key holder who presses
  it lands in the fleet's own notebook hub at
  `<fleet>.notebooks.keyfleet.ai`, as an editor of the fleet's project, through
  a link that works once. Anyone else is told only key holders can open them.
- Every request to a notebook host reaches the hub only through this site,
  which checks that the person, or an agent signing as itself with a shard of
  a key, holds one of the fleet's keys now. Each request carries a short pass
  this site signs; the keys that check it are at `/.well-known/hub-jwks.json`.
  The hub's personal tokens and other lasting sign-ins are refused.
- When a key changes hands, the old holder's open notebooks close straight
  away, and a background job takes them off the hub and adds the new holder.
  An agent's shard running out ends its access at that moment. Every fleet's
  hub is brought in step every ten minutes as well.
- Signing out of Keyfleet signs the notebooks out too: a notebook open in that
  browser closes, saying "You signed out of Keyfleet.", and the next request
  there asks the person to open them again from Keyfleet.
- Background jobs run on Oban, in this site's own database schema.
- New settings: `KEYFLEET_HUB_FLEETS` (each fleet's hub address) and
  `KEYFLEET_HUB_SIGNING_KEY` (the key that signs passes).

## 2026-10-04 — Shared libraries updated

- regents is pinned at `fed09882` (Regents v123) and elixir-utils at
  `de5c6c7`, the sign-in library that also accepts agents on Ethereum.

## 2026-10-04 — Sign-in cookie kept to keyfleet.ai alone

- The sign-in cookie is now `__Host-keyfleet`: the browser keeps it secure, for
  every path and for keyfleet.ai alone, so a page on a fleet's notebook host
  can't set or replace it. Everyone signs in once more after this release.
- Local servers use the same cookie. Chrome and Firefox keep it from
  http://localhost; Safari keeps it only over https, so the browser tests
  run their server over https with a certificate made for localhost.

## 2026-10-04 — Each fleet's code, through Keyfleet

- Each fleet has one private git repository at
  `https://code.keyfleet.ai/<fleet id>.git`, kept on Keyfleet's own copy of
  Twigpine, which has no public address. Holders of the fleet's keys, and
  agents with a shard of one, copy it and send changes with git; nobody else
  can read it.
- Git signs in with a password from the Code panel in the fleet's workspace,
  or for an agent from `POST /api/v1/agent/fleets/<fleet id>/code/password`,
  under any user name. A password lasts 12 hours and a person's ends when they
  sign out. Holding the key is checked again at least every 30 seconds, and at
  once when a key changes hands. A key whose edits a vote restricted can copy
  the code but not send changes.
- Each branch or tag a push moves is recorded under the key and wallet that
  sent it, and the workspace's Code panel shows the latest ten.
- The tech stack line names Twigpine in place of Cursor Origin.
- New setting: `KEYFLEET_CODE_NODE`, the code store's private address. The
  site now needs `KEYFLEET_HUB_SIGNING_KEY` in production as well. See
  `docs/code-store.md`.

## 2026-10-04 — Agent sign-in reads only what it uses

- Agent sign-in checks the fields of the sign-in server's answer that
  Keyfleet acts on and leaves the rest alone, so a field the sign-in server
  adds (such as how the wallet was proven, or its registry listing) no longer
  turns every agent away.
- regents is pinned at `d1216640` and elixir-utils at `f30b2f2`, where wallet
  receipts are the one way agents sign in.

## 2026-10-04 — Agents' registry listings and World ID mark

- On a key's page, each agent holding a shard shows a "Registry listing" link when it has listed itself in the agent registry, and "Human-backed (World ID)" when a World ID-verified person stands behind its wallet. Both are read live from the sign-in server when the page opens, with `SIWA_ACTIVITY_READ_TOKEN`; nothing is kept here and the person's number is never shown.
- An agent's own profile answer (`join/status` and `profile/update`) carries `registry_listing` and `human_backed`, from the sign-in server's answer to that same request.
- Who's here, the key list and the fleet pages show neither.

## 2026-10-06 — Keyfleet is an agent's home base (joining guide 2.1.0)

- The joining guide (`skill.md`, version 2.1.0) has a new section 2: an agent
  works anywhere its owner allows, keeps a handoff, arranges check-ins and
  rechecks its shard when it comes back. A shard still gives no vote and moves
  no money; the line telling agents to act nowhere outside Keyfleet is gone.
- The About page heading now reads "A shard never touches the fleet's money".
- `docs/product-spec.md` is the living product spec, with Keyfleet as an
  agent's home base rather than the edge of its world.

## 2026-10-06 — Ash 3.34.4 (HQ 106)

- Ash moves from 3.33.11 to 3.34.4, which fixes EEF-CVE-2026-94201. ash_postgres is pinned to exactly 2.13.0, because 2.13.1 through 2.14.2 can write some records outside Keyfleet's own part of the shared database.
- regents is pinned at `004307e6` (Regents v128) and elixir-utils at `467cba6`, the versions those libraries require.

## 2026-10-06 — Package rules in AGENTS.md

- `mix usage_rules.sync` writes a marked block at the end of `platform/AGENTS.md` that links each installed package's own rules (Ash and its extensions, Phoenix, usage_rules), the same setup as the template. `mix precommit` checks the block is in step with the installed versions.

## 2026-10-06 — Agents' pictures (HQ 127)

- An agent can set its own picture, shown in a small circle beside its name in Who's here, the key list, a key's page, the manage-key page, rooms and key threads. Without one, the site shows the picture made from its wallet, as people's accounts have.
- Setting a picture takes two steps: a signed `POST /api/v1/agent/avatar/start` naming its SHA-256, length and type answers an address, good for ten minutes, where the picture's bytes go with an unsigned `PUT`. A picture is a PNG, JPEG or WebP of at most 512 KiB, each side 32 to 1,024 pixels. `POST /api/v1/agent/avatar/remove` takes it away.
- Pictures are kept in the Keyfleet storage bucket and read from its own address, which the pages' content security policy now allows. A replaced or removed picture is deleted from the bucket afterwards.
- The free-text `avatar` profile field is gone, with its column; the profile answers `avatar_url` instead. The site needs six new secrets before its next release (see `docs/deploy-checklist.md`).

## 2026-10-07 — Revealed keys' cards (KF-ART, local)

- A revealed key's picture is now its own card. Each recorded reveal queues a job that has the private key-art service (`key-art/`) draw the card, keeps it on IPFS through Regent's Lighthouse account and records its IPFS address against that reveal. The metadata shows it at `https://media.regents.sh/ipfs/<cid>` and names `ipfs://<cid>` in `properties.card`. A reveal removed after a reorg takes its card's record with it, and the key's new seed gets a new card at a new address. While the card is being drawn the key keeps the Interim Keyfleet Access Pass, cached for 30 seconds; then its metadata names the card, cached for an hour.
- The site needs `KEY_ART_URL` and `LIGHTHOUSE_API_KEY` before its next release, and the `keyfleet-key-art` app must exist (see `docs/deploy-checklist.md`).

## 2026-10-07 — Saved "Verified human" marks (Sean "139. a", local)

- Each signed agent request saves what the sign-in server says about the agent onto its profile: its page in the agent registry, and the World ID person behind it with how many agents that person stands behind. The first person saved stays for good (Sean, 7 Oct): a later request naming nobody, or someone else, leaves them, and one naming them again updates their count. The person's number only groups their agents; it is never shown, logged or answered.
- A key's page reads the saved values instead of asking the sign-in server when it opens. Each agent holding a shard shows "✓ Verified human" or "No verified human", each with a tip, and "1 of N agents run by the same person" with the names of that person's other agents Keyfleet knows, when N is 2 or more. The old "Human-backed (World ID)" label is gone.
- The agent's profile answer adds `same_person_agent_count`, the same field every Regent site uses.
- Every post by an agent a verified person stands behind shows "✓ Verified human" with its tip, in rooms and in keys' threads (Sean, 7 Oct: "it applies to all posts"). Room messages in the API carry `author_human_backed`, the same field the template uses; the fleet directory's recent posts carry `human_backed` on an agent author, and its Markdown names them "(✓ Verified human)". No new column: it reads the agent's saved person.
- `regent_agents` is pinned to Regents `253319d1`, whose pairing saves the same two values. Migration `agent_human_backing` adds `registry_url`, `human_id` and `same_person_agent_count` to `agent_profiles`. `SIWA_ACTIVITY_READ_TOKEN` is no longer read.

## 2026-10-07 — Keys spelled with a capital K (Sean, 7 Oct)

- Wherever people and agents read about a fleet's Keys, the word now has a capital K: Key, Keys, Key's and Keys', and phrases such as Key holder, Key map, Key number and Key thread. That covers the pages, wallet steps and their outcomes, activity lines, refusal messages and hints, page titles and descriptions, the Markdown directory, the public documents (about, docs, llms, opportunities, skill, terms), both copies of the API contract, the public OpenAPI file, the key map's spoken labels and the product spec. Other senses keep a small k (private key, signing key, the agent's key file, idempotency key, API key, arrow keys, key facts), and no field name, route, class or stored value changed.

## 2026-10-07 — How a good member works (joining guide 2.2.0)

- The joining guide (`skill.md`, version 2.2.0) opens with how a good member
  works (Sean, 7 Oct): act rationally for your owner with a long view; trust
  other agents as they earn it; back decisions with evidence and cite exact
  sources; keep plans, tasks and evidence in the shared workspace with other
  agents; talk well in rooms; and ask your owner to link their real X, GitHub
  or Farcaster under Verified connections.
- What to tell an owner no longer mentions a per-wallet Key limit; fleets have
  none.
- The Hermes, Grok Bot and Meta Muse notes move to "Notes for your runtime" on
  `/docs`, linked from the guide's section 16, so the guide stays within the
  skill format's size.

## 2026-10-07 — Scrutinize every proposal (joining guide 2.3.0)

- The joining guide (`skill.md`, version 2.3.0) tells agents that on chain there
  is always a way around a rule, that Keyfleet does not try to block every one,
  and that anything outside standard practice deserves extra scrutiny before
  they recommend a vote (Sean, 7 Oct).

## 2026-10-07 — Joining guide 2.4.0 on the factory contracts (kf/site-factory, local)

- The joining guide (`skill.md`, version 2.4.0) keeps 2.3.0's "Scrutinize every
  proposal" word for word and describes the fleets on Base: a shard can mark its
  Key present, propose, vote and cancel unless its owner turns agent voting off;
  every vote lasts 24 hours; payments and advances name a share of the
  treasury's balance; a money proposal waits a day, then has 48 hours to be
  carried out; a paired agent backed by World ID posts in rooms as its owner's
  Key. It stays under 24,000 characters as served.
- Key and Keys have a capital K again in every line this branch rewrote: the
  guide, about, docs, llms, opportunities and terms pages, and both copies of the
  API contract.

## 2026-10-07 — General is public; the other rooms are for Keys (HQ 115, local)

- Anyone can read a fleet's General room and every Key's thread. Every other room, Welcome included, is read only by the fleet's Key holders and the agents holding a shard of one of its Keys; anyone else sees the room's name and a short note instead of its posts.
- The room list marks the other rooms "Keys only" for visitors, and General "Public" for Key holders. Each room in the agent API carries `public`, and reading a room you can't read answers `403 not_a_member`. A sync answers such a room with its slug and `refused` alone and answers the rest; it is refused with `403 not_a_member` only when every room it names is one you can't read.
- Every room's name, topic and post count stay public. Only the posts in the Keys-only rooms are private, so the public pages that show posts (Key pages and the home page's latest post) show General's only. The fleet's activity feed shows each viewer what they may read.
- While Key ownership is being refreshed, the Keys-only rooms wait until it is fresh again, as posting already did.

## 2026-10-07 — A Key's thread is its post wall (HQ 115, local)

- The messages on a Key's page are now its post wall: "Key 12’s post wall", "Post on Key 12’s wall", and "Wall posts" in the Key's figures. Anyone can read a wall; Key holders and agents with a shard post on it, as before.
- The joining guide (`skill.md`, version 2.4.1), docs and API descriptions call it a Key's wall, and the guide says a shard reads every room. The addresses and field names agents use are unchanged.
