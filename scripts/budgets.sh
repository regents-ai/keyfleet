#!/usr/bin/env bash
# Lighthouse CI budgets. Loads the homepage, Classic #1, the Regents Club, a
# room and a poll three times each in headless Chromium, as Lighthouse's
# default mobile setup sees them (a Moto G Power's screen, simulated slow 4G,
# a processor four times slower), and fails when the median run of any page
# breaks a budget in platform/lighthouserc.cjs. scripts/release.sh runs it
# against the image it has just started; it runs against any server too:
#
#   scripts/budgets.sh http://localhost:4000
#
# Name the server as its PHX_HOST names it (localhost for the release image):
# the live connection only opens from the site's own address. This is a lab
# measurement in Chromium; visitors' own timings are KeyfleetWeb.Vitals.
#
# Chromium is Playwright's (`npx playwright install chromium` in platform/),
# or the one CHROME_PATH names. It never opens a window. The reports are kept
# in platform/_build/lighthouse/.lighthouseci, one JSON and one HTML a run.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
base="${1:?usage: scripts/budgets.sh <site address, such as http://localhost:4000>}"
cd "$root/platform"

if [[ -z ${CHROME_PATH:-} ]]; then
  CHROME_PATH="$(node -e 'process.stdout.write(require("@playwright/test").chromium.executablePath())')"
fi
if [[ ! -x $CHROME_PATH ]]; then
  echo "Budgets failed: no Chromium at $CHROME_PATH. Run npx playwright install chromium in platform/, or set CHROME_PATH." >&2
  exit 1
fi
export CHROME_PATH KEYFLEET_BUDGET_URL="$base"

# A page whose live connection never opens is still drawn, and would be
# measured as if it were whole, so the homepage must connect first.
node - "$base" <<'EOF'
const {chromium} = require("@playwright/test")
const [base] = process.argv.slice(2)
const args = process.getuid?.() === 0 ? ["--no-sandbox"] : []
;(async () => {
  const browser = await chromium.launch({executablePath: process.env.CHROME_PATH, headless: true, args})
  try {
    const page = await browser.newPage()
    await page.goto(base, {waitUntil: "load"})
    await page.waitForSelector("[data-phx-main].phx-connected", {timeout: 15000})
  } catch (error) {
    console.error(`Budgets failed: the homepage at ${base} never opened its live connection (${error.message.split("\n")[0]}).`)
    process.exitCode = 1
  } finally {
    await browser.close()
  }
})()
EOF

reports="$root/platform/_build/lighthouse"
rm -rf "$reports"
mkdir -p "$reports"
config="$root/platform/lighthouserc.cjs"
# Lighthouse CI as platform/package.json pins it, installed by npm ci.
lhci="$root/platform/node_modules/.bin/lhci"

echo "==> Loading each page three times in Lighthouse (mobile, simulated slow 4G)"
(cd "$reports" && "$lhci" collect --config="$config")

passed=true
(cd "$reports" && "$lhci" assert --config="$config") || passed=false

# The median of each page's runs, as the assertions judge them, and the page
# Lighthouse ended on when it differs from the one asked for.
node - "$reports/.lighthouseci" <<'EOF'
const fs = require("node:fs")
const path = require("node:path")
const [dir] = process.argv.slice(2)
const runs = fs.readdirSync(dir).filter(name => /^lhr-.*\.json$/.test(name))
  .map(name => JSON.parse(fs.readFileSync(path.join(dir, name), "utf8")))
const median = values => values.sort((a, b) => a - b)[Math.floor(values.length / 2)]
const size = (lhr, type) =>
  lhr.audits["resource-summary"].details.items.find(item => item.resourceType === type)?.transferSize ?? 0
const pages = new Map()
for (const lhr of runs) pages.set(lhr.requestedUrl, [...(pages.get(lhr.requestedUrl) ?? []), lhr])
console.log("\nMedian of each page's runs: LCP ms, CLS, TBT ms, script KiB, stylesheet KiB")
for (const [url, lhrs] of pages) {
  const of = read => median(lhrs.map(read))
  const row = [
    Math.round(of(lhr => lhr.audits["largest-contentful-paint"].numericValue)),
    of(lhr => lhr.audits["cumulative-layout-shift"].numericValue).toFixed(3),
    Math.round(of(lhr => lhr.audits["total-blocking-time"].numericValue)),
    (of(lhr => size(lhr, "script")) / 1024).toFixed(1),
    (of(lhr => size(lhr, "stylesheet")) / 1024).toFixed(1),
  ]
  const ended = lhrs[0].finalDisplayedUrl
  console.log(`  ${new URL(url).pathname.padEnd(54)} ${row.join("  ")}  (${lhrs.length} runs)`)
  if (ended !== url) console.log(`    measured ${new URL(ended).pathname}: the address sent the browser there`)
}
EOF

if [[ $passed != true ]]; then
  echo "Budgets failed: a page's median run broke a budget above. Reports: $reports/.lighthouseci" >&2
  exit 1
fi
echo "Budgets passed. Reports: $reports/.lighthouseci"
