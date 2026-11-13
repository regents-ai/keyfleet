import {randomBytes} from "node:crypto"
import {defineConfig, devices} from "@playwright/test"

// The specs here sell and move keys, and issue and end their shards, on the
// server while a page watches, and land the steps a page's wallet buttons
// send. A key's profile is checked in Chromium, Firefox and WebKit; the map,
// the fleet page's motion, the wallet buttons, the Keys Vote, Mark present
// and Claim all send, a key's shards, muting a key
// in a room, the copy buttons, the pages' security policy, the links
// between the in-app pages, the agent tools the pages register and managing
// paired agents on the Agents page, the Treasury's last reading and its
// refresh icon, new work gliding into a fleet's workstream, a visit told
// again from the server's lines, the city button beside an open fleet's name
// with its bar, a new owner's setup list from the purchase to its last
// step, Block and Delete conversation asking first in a direct message, the
// homepage's value cards opening Classic's pages, the workspace's Graph canvas
// panning, zooming, rearranging and lighting a line, and a fleet's Worldline
// read signed out, in Chromium.
// They call `Keyfleet.BrowserChain` and `Keyfleet.BrowserAgents` on the server
// over Erlang distribution, so the server runs as a named node on the loopback
// address, with a secret cookie and a fixed distribution port instead of epmd.
// The server checks agents' signed requests through a stand-in sign-in server
// that `Keyfleet.BrowserAgents` starts.
//
// The server gets a database of its own, the partition's name with
// `_fleet_map` after it, created and brought up to date before the server
// starts; the ExUnit suite never reads it. The server holds it in one
// transaction it never commits, so the keys and shards a run records are
// gone when the server stops, and every run starts from the same unsold
// fleets.
const port = process.env.PORT || "4502"
const partition = `${process.env.MIX_TEST_PARTITION ?? ""}_fleet_map`
const baseURL = `https://localhost:${port}`

// Workers inherit the cookie from the main process, which makes it first.
process.env.KEYFLEET_BROWSER_COOKIE ??= randomBytes(24).toString("hex")
process.env.KEYFLEET_BROWSER_DIST_PORT = String(Number(port) + 20_000)

const env = `MIX_ENV=test MIX_TEST_PARTITION=${partition}`
const distribution = `-start_epmd false -erl_epmd_port ${process.env.KEYFLEET_BROWSER_DIST_PORT} -kernel inet_dist_use_interface {127,0,0,1}`

export default defineConfig({
  testDir: "./test/browser",
  testMatch: ["fleet_map.spec.ts", "key_profile.spec.ts", "fleet_motion.spec.ts", "fleet_layout.spec.ts", "wallet_buttons.spec.ts", "wallet_keys.spec.ts", "key_shards.spec.ts", "room_mutes.spec.ts", "copy_buttons.spec.ts", "content_security_policy.spec.ts", "shell_links.spec.ts", "early_page.spec.ts", "agent_tools.spec.ts", "account_agents.spec.ts", "key_card.spec.ts", "workspace_motion.spec.ts", "group_flow.spec.ts", "treasury_read.spec.ts", "visits.spec.ts", "sea_lift.spec.ts", "setup_list.spec.ts", "fleet_search.spec.ts", "dm_confirm.spec.ts", "homepage_cards.spec.ts", "tree_canvas.spec.ts", "worldline.spec.ts"],
  fullyParallel: false,
  workers: 1,
  forbidOnly: true,
  retries: 0,
  reporter: "line",
  // The server's certificate is one it made for itself.
  use: {
    baseURL,
    ignoreHTTPSErrors: true,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  webServer: {
    command: [
      "mkdir -p tmp/cert && rm -f tmp/walk-lines.jsonl",
      "(test -f tmp/cert/localhost.pem || openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=localhost -addext subjectAltName=DNS:localhost -keyout tmp/cert/localhost_key.pem -out tmp/cert/localhost.pem)",
      `${env} mix ecto.create --quiet`,
      `${env} mix keyfleet.setup_local_auth`,
      `${env} KEYFLEET_BROWSER_TEST=1 elixir --name keyfleet_browser@127.0.0.1 --cookie "$KEYFLEET_BROWSER_COOKIE" --erl '${distribution}' -S mix run --no-halt -e 'Keyfleet.BrowserChain.hold_database!(); Keyfleet.TestChainNode.start!(); Keyfleet.BrowserAgents.start!()'`,
    ].join(" && "),
    url: `${baseURL}/`,
    ignoreHTTPSErrors: true,
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
