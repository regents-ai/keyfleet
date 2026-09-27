import {randomBytes} from "node:crypto"
import {defineConfig, devices} from "@playwright/test"

// The specs here sell, move and pair keys on the server while a page watches,
// and land the steps a page's wallet buttons send. A key's profile is checked
// in Chromium, Firefox and WebKit; the map, the fleet page's motion, the
// wallet buttons and the copy buttons in Chromium.
// They call `Keyfleet.BrowserChain` on the server over Erlang distribution, so
// the server runs as a named node on the loopback address, with a secret
// cookie and a fixed distribution port instead of epmd.
//
// The server gets a database of its own, the partition's name with
// `_fleet_map` after it, created and brought up to date before the server
// starts; the ExUnit suite never reads it. The server holds it in one
// transaction it never commits, so the keys a run sells, moves and pairs are
// gone when the server stops, and every run starts from the same unsold
// fleets.
const port = process.env.PORT || "4002"
const partition = `${process.env.MIX_TEST_PARTITION ?? ""}_fleet_map`
const baseURL = `http://127.0.0.1:${port}`

// Workers inherit the cookie from the main process, which makes it first.
process.env.KEYFLEET_BROWSER_COOKIE ??= randomBytes(24).toString("hex")
process.env.KEYFLEET_BROWSER_DIST_PORT = String(Number(port) + 20_000)

const env = `MIX_ENV=test MIX_TEST_PARTITION=${partition}`
const distribution = `-start_epmd false -erl_epmd_port ${process.env.KEYFLEET_BROWSER_DIST_PORT} -kernel inet_dist_use_interface {127,0,0,1}`

export default defineConfig({
  testDir: "./test/browser",
  testMatch: ["fleet_map.spec.ts", "key_profile.spec.ts", "fleet_motion.spec.ts", "wallet_buttons.spec.ts", "copy_buttons.spec.ts"],
  fullyParallel: false,
  workers: 1,
  forbidOnly: true,
  retries: 0,
  reporter: "line",
  use: {
    baseURL,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  webServer: {
    command: [
      `${env} mix ecto.create --quiet`,
      `${env} mix run -e 'Keyfleet.LocalDatabaseFixture.ensure_human_accounts!()'`,
      `${env} KEYFLEET_BROWSER_TEST=1 elixir --name keyfleet_browser@127.0.0.1 --cookie "$KEYFLEET_BROWSER_COOKIE" --erl '${distribution}' -S mix run --no-halt -e 'Keyfleet.BrowserChain.hold_database!()'`,
    ].join(" && "),
    url: `${baseURL}/`,
    reuseExistingServer: false,
    timeout: 180_000,
  },
  projects: [
    // Headless Chromium lends WebGPU only when asked, so a key's foil really
    // draws there; Firefox and WebKit have none and show the still foil.
    {
      name: "chromium",
      use: {...devices["Desktop Chrome"], launchOptions: {args: ["--enable-unsafe-webgpu"]}},
    },
    {
      name: "firefox",
      testMatch: ["key_profile.spec.ts"],
      use: {...devices["Desktop Firefox"]},
    },
    {
      name: "webkit",
      testMatch: ["key_profile.spec.ts"],
      use: {...devices["Desktop Safari"]},
    },
  ],
})
