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
  webServer: {
    command:
      "MIX_ENV=test KEYFLEET_BROWSER_TEST=1 mix phx.server",
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
