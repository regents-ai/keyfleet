# Local component workshop

Open `/showcase` on a development or test server using `localhost` or `127.0.0.1`.
The production configuration omits its routes. HTTP requests and connected
page mounts both require a loopback peer and a loopback hostname; forwarded
headers do not grant access. Gallery styles and metadata use the same guard.

## What it shows

The workshop renders the active components installed from `regent_ui` and
`KeyfleetWeb.Components`, plus both layouts, composed in the shared
`Regent.Structure` frames, rows, section bars and panels. The shell preview
includes working navigation and theme behavior but omits sign-in controls.

Palette cards pair each site's light/dark colors with a real
surface/text/primary preview. Four editable colors (background, surface, text
and primary) are stored separately for each site/mode in browser storage; Reset
affects only the selected palette. The Shimmer color picker overrides
`--rg-shimmer-color` for the workshop document and resets on reload.

`Regent.Structure.capability_card/1` is the shared card, not workshop-specific
HTML. Its API, together with every component's attributes and slots, the
installed Ash domain/resource/action metadata and the exported utility APIs, is
listed at `/showcase/catalog`. The catalog never reads resource records.

## Privy working reference

`/showcase/privy` uses the real account control and auth bridge, not the
separate wallet fixture in the main gallery. It includes configuration
instructions, header Sign In/Disconnect, in-page connection controls and the
selected wallet. Controls are disabled with an explanation when configuration is
missing or the server uses a test verifier. No configuration values, tokens or
provider objects are displayed, and the page requests no transaction or extra
signature.

For real testing, use the configured development server and a Privy-allowed
localhost origin with `PRIVY_APP_ID` and `PRIVY_VERIFICATION_KEY` set. Prepare
the local database (`keyfleet_dev`), run `mix keyfleet.setup_local_auth`,
then `mix assets.build` and `mix phx.server`. Do not use browser-test
configuration as proof of real Privy sign-in.

## Key map working reference

`/showcase/key-map` runs the fleet key map on made-up data, with no chain or
database behind it. Buttons switch between the three fleet shapes: Classic
(1,024 keys) and Accelerant (2,000), each sold out but for its last key, and
Fibonacci, whose levels keep opening, a few rows into level 19 with 17,768 keys
sold. The Fibonacci map draws the levels sold and the level on sale. Every 97th
key is marked as yours and every 7th as having an agent. Choosing a key, by click or by Enter, only updates the line under the map.

The map loads as its own script chunk the first time a page shows one. Its drag
and coast are adapted from `thiings-grid`; see `THIRD_PARTY_NOTICES.md`.

## Utility effects

- Wallet fixture: a separate local provider demonstrates connect/disconnect,
  overlapping presses, confirmation, rejection and revert. It never enters the
  real wallet store or sends a network request.
- Create/add/reset items and edits use a local Ash sample action with an
  in-memory data layer. Copy writes the displayed result through the browser
  clipboard API. These examples never write product records.
- Privy verification: signs an ephemeral fixture token and calls `RegentPrivy`
  for valid, expired and incorrect-audience outcomes. No fixture token enters an
  authentication endpoint; no key or token is displayed or retained.
- Postgres: a fixed read-only diagnostic accepts only the prepared loopback
  test database naming convention. It refuses other database settings.

## Run in an isolated worktree

Give the worktree its own `MIX_TEST_PARTITION` and a unique `PORT`. Install
locked Mix and npm dependencies, then run `mix assets.build`. A prepared test database can be
created with `MIX_ENV=test mix ecto.create`.

Run the disposable test server with that partition and port:

```sh
env MIX_ENV=test KEYFLEET_BROWSER_TEST=1 mix run --no-halt -e 'Ecto.Adapters.SQL.Sandbox.mode(Keyfleet.Repo, :auto)'
```

That command belongs only in the isolated test context. Use its printed URL and
append `/showcase`.

## Focused verification

```sh
mix test test/keyfleet_web/showcase
npm run typecheck
npm test
PORT=<port> npx playwright test --config playwright.showcase.config.ts --project=chromium
```

The Chromium run is the one that gates a change. It checks the key map by mouse,
wheel, keyboard and touch, and measures its frame times, scripting time, build
time and tile count on a laptop with the largest and the middle fleet, and on a
phone with the processor slowed four times. The `firefox` and `webkit` projects
run the same key map checks, and need browser builds that match this Playwright
release (`npx playwright install firefox webkit`).

The dedicated browser configuration avoids the product suite's seeding and
global teardown. Failures retain screenshots and traces in `test-results/`.
