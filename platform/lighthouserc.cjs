// Lighthouse CI budgets (scripts/budgets.sh, which scripts/release.sh runs
// against the image it has just started). A lab measurement in headless
// Chromium with Lighthouse's default mobile setup: a Moto G Power's screen and
// user agent, simulated slow 4G and a processor four times slower than the
// machine's. Visitors' own timings are counted separately (KeyfleetWeb.Vitals).
//
// Each page is loaded three times. The median run of every page must keep
// Largest Contentful Paint under 2.5 s, Cumulative Layout Shift under 0.1 and
// Total Blocking Time, the lab's stand-in for Interaction to Next Paint, under
// 200 ms, and its stylesheets within app.css's 60 KiB on the wire
// (assets/test/budgets.budget.ts). That file's 175 KiB is for app.js alone,
// while a page also loads the chunks app.js imports: about 172 KiB in all on
// 18 Oct 2026, so a page's whole script is held to 180 KiB.

const base = process.env.KEYFLEET_BUDGET_URL
if (!base) throw new Error("Set KEYFLEET_BUDGET_URL to the site to measure, such as http://localhost:4000")

// No poll exists in a fresh database, and a poll's page shows that it can't
// be found; name a real one to measure one with its votes.
const poll = process.env.KEYFLEET_BUDGET_POLL || "00000000-0000-4000-8000-000000000000"

const pages = [
  "/",
  "/classic/1",
  "/app/fleets/regents_club",
  "/classic/1/rooms/general",
  `/classic/1/polls/${poll}`,
]

const median = {aggregationMethod: "median"}

module.exports = {
  ci: {
    collect: {
      url: pages.map(page => new URL(page, base).href),
      numberOfRuns: 3,
      chromePath: process.env.CHROME_PATH,
      settings: {
        onlyCategories: ["performance"],
        // Headless, so no window opens, and a headless browser says it is
        // driven by a program (navigator.webdriver), so these runs never send
        // visitors' page timings (assets/js/vitals.ts). Chromium refuses its
        // sandbox to root, as in a container.
        chromeFlags: ["--headless=new", ...(process.getuid?.() === 0 ? ["--no-sandbox"] : [])].join(" "),
      },
    },
    assert: {
      assertions: {
        "largest-contentful-paint": ["error", {maxNumericValue: 2500, ...median}],
        "cumulative-layout-shift": ["error", {maxNumericValue: 0.1, ...median}],
        "total-blocking-time": ["error", {maxNumericValue: 200, ...median}],
        "resource-summary:stylesheet:size": ["error", {maxNumericValue: 60 * 1024, ...median}],
        "resource-summary:script:size": ["error", {maxNumericValue: 180 * 1024, ...median}],
      },
    },
  },
}
