import {defineConfig, devices} from "@playwright/test"

const baseURL = `http://127.0.0.1:${process.env.PORT || "4002"}`

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
  ],
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
  // The fleet pages need the four fleets in the catalog, so they are put there
  // before the server starts; they are never deployed, so nothing is on sale.
  webServer: {
    command:
      "MIX_ENV=test mix run -e 'Keyfleet.Fleets.bootstrap_catalog!()' && MIX_ENV=test KEYFLEET_BROWSER_TEST=1 mix phx.server",
    url: `${baseURL}/`,
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
