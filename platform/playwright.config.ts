import {defineConfig, devices} from "@playwright/test"

const baseURL = `https://localhost:${process.env.PORT || "4502"}`
// The server gets a database of its own, the partition's name with `_walk`
// after it, made afresh for each run, so the ExUnit suite can run beside it.
const env = `MIX_ENV=test MIX_TEST_PARTITION=${process.env.MIX_TEST_PARTITION ?? ""}_walk`

export default defineConfig({
  testDir: "./test/browser",
  // The component workshop and key map exist only when the local showcase is compiled in;
  // playwright.showcase.config.ts runs them against a server built that way.
  // playwright.chain.config.ts runs the specs that drive the chain, on a database of their own,
  // and playwright.devices.config.ts the first visit's flows and accessibility on that server.
  testIgnore: [
    "main_flows.spec.ts",
    "accessibility.spec.ts",
    "showcase.spec.ts",
    "key_map.spec.ts",
    "key_map_performance.spec.ts",
    "fleet_map.spec.ts",
    "key_profile.spec.ts",
    "fleet_motion.spec.ts",
    "fleet_layout.spec.ts",
    "wallet_buttons.spec.ts",
    "wallet_keys.spec.ts",
    "key_shards.spec.ts",
    "room_mutes.spec.ts",
    "dm_confirm.spec.ts",
    "copy_buttons.spec.ts",
    "content_security_policy.spec.ts",
    "shell_links.spec.ts",
    "early_page.spec.ts",
    "agent_tools.spec.ts",
    "account_agents.spec.ts",
    "key_card.spec.ts",
    "workspace_motion.spec.ts",
    "group_flow.spec.ts",
    "treasury_read.spec.ts",
    "visits.spec.ts",
    "sea_lift.spec.ts",
    "fleet_prompts.spec.ts",
    "fleet_search.spec.ts",
    "homepage_cards.spec.ts",
    "tree_canvas.spec.ts",
    "atlas.spec.ts",
    "worldline.spec.ts",
    "fleet_tour.spec.ts",
  ],
  fullyParallel: false,
  workers: 1,
  forbidOnly: true,
  retries: 0,
  reporter: "line",
  // The server's certificate is one it made for itself. Every walk starts
  // with the fleet page's guided tours seen, so neither opens over what it
  // presses.
  use: {
    baseURL,
    ignoreHTTPSErrors: true,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    storageState: {
      cookies: [],
      origins: [
        {
          origin: baseURL,
          localStorage: [
            {name: "keyfleet:tour:visitor", value: "seen"},
            {name: "keyfleet:tour:holder", value: "seen"},
          ],
        },
      ],
    },
  },
  // The database is dropped, made and brought up to date first, as the chain
  // config does, then the four fleets are put in the catalog for the fleet
  // pages. They are never deployed, so nothing is on sale. This runs without
  // KEYFLEET_BROWSER_TEST, which would open the port before the server is ready.
  webServer: {
    command: [
      "mkdir -p tmp/cert && rm -f tmp/walk-lines.jsonl",
      "(test -f tmp/cert/localhost.pem || openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=localhost -addext subjectAltName=DNS:localhost -keyout tmp/cert/localhost_key.pem -out tmp/cert/localhost.pem)",
      `${env} mix ecto.drop --quiet`,
      `${env} mix ecto.create --quiet`,
      `${env} mix keyfleet.setup_local_auth`,
      `${env} mix run -e 'Keyfleet.Fleets.bootstrap_catalog!()'`,
      `${env} KEYFLEET_BROWSER_TEST=1 mix phx.server`,
    ].join(" && "),
    url: `${baseURL}/`,
    ignoreHTTPSErrors: true,
    reuseExistingServer: false,
    timeout: 120_000,
  },
  projects: [
    {
      name: "chromium",
      use: {...devices["Desktop Chrome"]},
    },
  ],
})
