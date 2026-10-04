import {defineConfig, devices} from "@playwright/test"

const baseURL = `https://localhost:${process.env.PORT || "4002"}`

export default defineConfig({
  testDir: "./test/browser",
  // The component workshop and key map exist only when the local showcase is compiled in;
  // playwright.showcase.config.ts runs them against a server built that way.
  // playwright.chain.config.ts runs the specs that drive the chain, on a database of their own.
  testIgnore: [
    "showcase.spec.ts",
    "key_map.spec.ts",
    "key_map_performance.spec.ts",
    "fleet_map.spec.ts",
    "key_profile.spec.ts",
    "fleet_motion.spec.ts",
    "wallet_buttons.spec.ts",
    "key_shards.spec.ts",
    "room_mutes.spec.ts",
    "copy_buttons.spec.ts",
    "content_security_policy.spec.ts",
    "shell_links.spec.ts",
  ],
  fullyParallel: false,
  workers: 1,
  forbidOnly: true,
  retries: 0,
  reporter: "line",
  globalTeardown: "./test/browser/support/remove_browser_account.ts",
  // The server's certificate is one it made for itself.
  use: {
    baseURL,
    ignoreHTTPSErrors: true,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  // The database is created and brought up to date first, as the chain config
  // does, then the four fleets are put in the catalog for the fleet pages. They
  // are never deployed, so nothing is on sale. This runs without
  // KEYFLEET_BROWSER_TEST, which would open the port before the server is ready.
  webServer: {
    command: [
      "mkdir -p tmp/cert",
      "(test -f tmp/cert/localhost.pem || openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=localhost -addext subjectAltName=DNS:localhost -keyout tmp/cert/localhost_key.pem -out tmp/cert/localhost.pem)",
      "MIX_ENV=test mix ecto.create --quiet",
      "MIX_ENV=test mix keyfleet.setup_local_auth",
      "MIX_ENV=test mix run -e 'Keyfleet.Fleets.bootstrap_catalog!()'",
      "MIX_ENV=test KEYFLEET_BROWSER_TEST=1 mix phx.server",
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
