import {defineConfig, devices} from "@playwright/test"

// Use an already-running isolated worktree server. No product seeding or teardown.
// The key map is checked in all three engines; the rest of the workshop in Chromium.
export default defineConfig({
  testDir: "./test/browser",
  testMatch: ["showcase.spec.ts", "key_map.spec.ts", "key_map_performance.spec.ts"],
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: "line",
  // The test server answers over https, with a certificate it made for itself.
  use: {
    baseURL: `https://localhost:${process.env.PORT || "4502"}`,
    ignoreHTTPSErrors: true,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  projects: [
    {name: "chromium", use: {...devices["Desktop Chrome"]}},
    {name: "firefox", testMatch: "key_map.spec.ts", use: {...devices["Desktop Firefox"]}},
    {name: "webkit", testMatch: "key_map.spec.ts", use: {...devices["Desktop Safari"]}},
  ],
})
