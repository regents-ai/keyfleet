import {defineConfig, devices} from "@playwright/test"
import chain from "./playwright.chain.config"

// What a first-time visitor sees, at the screens they bring: the main flows
// signed out at an iPhone 15's and a Pixel 7's screen, touch and user agent,
// and the accessibility check of every main page, light and dark, wide and at
// a phone's width. Every run is Chromium, the one browser the Mac's tests run;
// Safari's own engine and real phones are checked by people instead
// (docs/launch-readiness/visitor-sessions.md).
//
// The server is the chain config's own, unchanged: the specs need a fleet
// that is open, and only that server can open one. Before any spec runs,
// club_world.ts opens the Regents Club with a post, a goal and a proposal,
// and leaves Classic #1 coming soon, as the site launches. The server's
// database is made afresh for each run, so every run starts the same.
export default defineConfig({
  ...chain,
  testMatch: ["main_flows.spec.ts", "accessibility.spec.ts"],
  globalSetup: "./test/browser/support/club_world.ts",
  projects: [
    {
      name: "iPhone 15",
      testMatch: "main_flows.spec.ts",
      use: {...devices["iPhone 15"], browserName: "chromium"},
    },
    {name: "Pixel 7", testMatch: "main_flows.spec.ts", use: {...devices["Pixel 7"]}},
    // Motion is reduced so axe reads every colour at rest, not halfway
    // through a fade.
    {
      name: "accessibility",
      testMatch: "accessibility.spec.ts",
      use: {...devices["Desktop Chrome"], contextOptions: {reducedMotion: "reduce"}},
    },
  ],
})
