#!/usr/bin/env bash
# A one-shot Lighthouse profile of a site's public pages, signed out: the
# homepage, Classic #1 and the Regents Club, five times each, one after
# another, as two phones. That is 30 ordinary page loads in all, never load.
#
#   platform/load/profile-live.sh <out dir> [site]
#
# The site is the local one, http://localhost:4000, unless another is named:
# the live site is profiled only as `platform/load/profile-live.sh <out dir>
# https://keyfleet.ai`.
#
# THIS IS LAB EMULATION IN CHROMIUM, NOT A REAL DEVICE. Both profiles run in
# headless Chromium on this machine with Lighthouse's simulated slow 4G (150 ms
# round trips, about 1.6 Mbit/s) and a processor four times slower than this
# machine's:
#
#   moto-g-power  Lighthouse's default mobile setup: a Moto G Power's screen
#                 (412 x 823 at 1.75x) and its Android Chrome user agent.
#   iphone        an iPhone's screen (390 x 844 at 3x) and its Safari user
#                 agent, with the same network and processor. Chromium still
#                 draws the page, not Safari's engine, so this shows what the
#                 site sends and lays out for an iPhone, not how fast an
#                 iPhone is.
#
# Real visitors' own timings, from their own devices, are KeyfleetWeb.Vitals.
# Each run starts a fresh browser profile, so it is signed out and has nothing
# cached. A browser driven this way says so, so the site counts none of these
# runs as a visitor.
#
# Into <out dir> go each run's JSON and HTML report
# (<profile>/<page>-<run>.report.json and .html) and summary.md, the median of
# each page's five runs, also printed at the end.
# Chromium is Playwright's (`npx playwright install chromium` in platform/),
# or the one CHROME_PATH names. It never opens a window.
set -euo pipefail

out="${1:?usage: platform/load/profile-live.sh <out dir> [site]}"
site="${2:-http://localhost:4000}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
cd "$(dirname "$0")/.."

if [[ -z ${CHROME_PATH:-} ]]; then
  CHROME_PATH="$(node -e 'process.stdout.write(require("@playwright/test").chromium.executablePath())')"
fi
if [[ ! -x $CHROME_PATH ]]; then
  echo "No Chromium at $CHROME_PATH. Run npx playwright install chromium in platform/, or set CHROME_PATH." >&2
  exit 1
fi
export CHROME_PATH

# Lighthouse as platform/package.json pins it, the version inside the
# Lighthouse CI that scripts/budgets.sh uses, so these figures and the release
# budgets come from the same engine.
lighthouse=(node_modules/.bin/lighthouse)

chrome_flags="--headless=new"
if [[ $(id -u) == 0 ]]; then chrome_flags+=" --no-sandbox"; fi

pages=(
  "home /"
  "classic-1 /classic/1"
  "regents-club /app/fleets/regents_club"
)

iphone_agent="Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"

for profile in moto-g-power iphone; do
  case $profile in
    moto-g-power) device=(--form-factor=mobile) ;;
    iphone)
      device=(--form-factor=mobile --screenEmulation.mobile --screenEmulation.width=390
        --screenEmulation.height=844 --screenEmulation.deviceScaleFactor=3
        "--emulatedUserAgent=$iphone_agent")
      ;;
  esac
  mkdir -p "$out/$profile"
  for entry in "${pages[@]}"; do
    read -r name path <<<"$entry"
    for run in 1 2 3 4 5; do
      echo "==> $profile $path, run $run of 5"
      "${lighthouse[@]}" "$site$path" "${device[@]}" \
        --quiet --only-categories=performance --throttling-method=simulate \
        --chrome-flags="$chrome_flags" \
        --output=json --output=html --output-path="$out/$profile/$name-$run"
    done
  done
done

# The median of each page's five runs, written to summary.md and printed.
node - "$out" "$site" <<'EOF'
const fs = require("node:fs")
const path = require("node:path")
const [out, site] = process.argv.slice(2)
const median = values => values.sort((a, b) => a - b)[Math.floor(values.length / 2)]
const lines = [
  `# Lighthouse profile of ${site}`,
  "",
  `${new Date().toISOString()}. Lab emulation in headless Chromium, not a real device: simulated slow 4G and a processor four times slower than this machine's. The median of five runs of each page, signed out.`,
  "",
  "| Profile | Page | Score | FCP ms | LCP ms | TBT ms | CLS | Speed Index ms | Server response ms | Measured |",
  "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
]
for (const profile of fs.readdirSync(out).filter(name => fs.statSync(path.join(out, name)).isDirectory()).sort()) {
  const runs = new Map()
  for (const file of fs.readdirSync(path.join(out, profile)).filter(name => name.endsWith(".report.json")).sort()) {
    const lhr = JSON.parse(fs.readFileSync(path.join(out, profile, file), "utf8"))
    const page = file.replace(/-\d+\.report\.json$/, "")
    runs.set(page, [...(runs.get(page) ?? []), lhr])
  }
  for (const [page, lhrs] of runs) {
    const audit = id => Math.round(median(lhrs.map(lhr => lhr.audits[id].numericValue)))
    const score = Math.round(median(lhrs.map(lhr => lhr.categories.performance.score ?? 0)) * 100)
    const cls = median(lhrs.map(lhr => lhr.audits["cumulative-layout-shift"].numericValue)).toFixed(3)
    const ended = [...new Set(lhrs.map(lhr => new URL(lhr.finalDisplayedUrl).pathname))].join(", ")
    lines.push(
      `| ${profile} | ${page} | ${score} | ${audit("first-contentful-paint")} | ${audit("largest-contentful-paint")} | ` +
        `${audit("total-blocking-time")} | ${cls} | ${audit("speed-index")} | ${audit("server-response-time")} | ${ended} (${lhrs.length} runs) |`,
    )
  }
}
const summary = lines.join("\n") + "\n"
fs.writeFileSync(path.join(out, "summary.md"), summary)
process.stdout.write("\n" + summary)
EOF
echo "Reports and summary.md are in $out"
