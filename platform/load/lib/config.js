// Where the load goes, what it is allowed to target, and the scenarios and
// targets each run is judged by. Everything here is read in the init context,
// so a refused target stops k6 before a single request leaves the machine.

// The live site and every address the production app answers on. A run
// against any of them, or any keyfleet.ai subdomain, stops at init, whatever
// else the environment says.
const REFUSED_HOSTS = [
  "keyfleet.ai",
  "www.keyfleet.ai",
  "keyfleet.fly.dev",
  "keyfleet.flycast",
  "keyfleet.internal",
]

// Every run is against the copy of the release local.sh or faults.sh starts
// on this computer, published on its loopback address.
const LOOPBACK_HOSTS = ["127.0.0.1", "localhost"]

// Sean's targets (launch readiness, 18 October 2026): page errors under 0.1%
// at 2,000 visitors, and a page drawn and connected within a second at p95.
const TARGETS = {
  http_req_failed: ["rate<0.001"],
  "http_req_duration{kind:page}": ["p(95)<1000"],
  lv_join_errors: ["rate<0.001"],
  lv_join_duration: ["p(95)<1000"],
}

function env(name, fallback) {
  const value = __ENV[name]
  return value === undefined || value === "" ? fallback : value
}

function integer(name, fallback) {
  const value = Number(env(name, String(fallback)))
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} must be a whole number, got ${__ENV[name]}`)
  return value
}

// "90", "90s", "10m" or "1h" as seconds; k6's stages take the same strings.
export function seconds(text) {
  const match = /^(\d+)(s|m|h)?$/.exec(String(text))
  if (!match) throw new Error(`not a duration: ${text} (write 90s, 10m or 1h)`)
  return Number(match[1]) * { s: 1, m: 60, h: 3600 }[match[2] || "s"]
}

// An origin as http://host[:port], with the host lowercased and any trailing
// dot dropped (keyfleet.ai. reaches the live site too). Only plain HTTP to
// this computer is accepted: the copy under load is published there, and
// lib/live.js hands the session cookie to the socket itself because no
// cookie jar sends a Secure cookie over plain HTTP.
function parseOrigin(name, raw) {
  const match = /^(https?):\/\/([^/:?#\s]+)(:\d+)?\/?$/i.exec(raw)
  if (!match) throw new Error(`${name} must be an origin such as http://127.0.0.1:4100, got ${raw}`)
  const scheme = match[1].toLowerCase()
  const host = match[2].toLowerCase().replace(/\.+$/, "")
  if (REFUSED_HOSTS.indexOf(host) !== -1 || /\.keyfleet\.ai$/.test(host)) {
    throw new Error(`Refusing to load ${host}: this kit never targets the live site.`)
  }
  if (scheme !== "http" || LOOPBACK_HOSTS.indexOf(host) === -1) {
    throw new Error(`Refusing to load ${raw}: ${name} must be http:// on this computer (127.0.0.1 or localhost), where local.sh publishes its copy.`)
  }
  return { scheme, host, origin: `${scheme}://${host}${match[3] || ""}` }
}

function loadSite() {
  const raw = __ENV.TARGET
  if (!raw) throw new Error("Set TARGET to the copy to load, such as -e TARGET=http://127.0.0.1:4100 (local.sh sets it)")
  const target = parseOrigin("TARGET", raw)
  // The socket's Origin must name the host the site believes it lives at
  // (PHX_HOST, localhost here); Phoenix compares the host alone.
  const origin = parseOrigin("ORIGIN", env("ORIGIN", target.origin)).origin
  return {
    base: target.origin,
    wsBase: target.origin.replace(/^http/, "ws"),
    origin,
  }
}

export const site = loadSite()

export const SCENARIO = env("SCENARIO", "smoke")

const PAGES = integer("PAGES", 2000)
const RAMP = env("RAMP", "10m")
const HOLD = env("HOLD", "10m")
const RAMP_DOWN = env("RAMP_DOWN", "2m")

// The phases of a faults or deploy run, as faults.sh and local.sh write
// them: [{name, from, to}] with times in milliseconds since the epoch, shared
// with the faults they apply and the deploy they make.
const PHASED = SCENARIO === "faults" || SCENARIO === "deploy"
const PHASES = PHASED ? JSON.parse(env("PHASES", "[]")) : []
if (PHASED && PHASES.length === 0) throw new Error(`the ${SCENARIO} scenario needs PHASES (${SCENARIO === "faults" ? "faults.sh" : "local.sh deploy"} sets it)`)

const dwellDefaults = { faults: [20, 60], smoke: [30, 60] }[SCENARIO] || [120, 600]

export const settings = {
  // How long a visitor keeps the page open, chosen evenly between the two.
  dwellMin: integer("DWELL_MIN_S", dwellDefaults[0]),
  dwellMax: integer("DWELL_MAX_S", dwellDefaults[1]),
  // "first": a VU fetches the page's stylesheet, scripts and fonts on its first
  // visit and keeps them, as a browser's cache would; "every": every visit is
  // a first-time visitor with an empty cache.
  assets: env("ASSETS", "first"),
  // A page whose connection dropped and is not back within this long is lost.
  rejoinDeadlineMs: integer("REJOIN_DEADLINE_S", 120) * 1000,
  // The reconnect storm: when every open page drops its connection at once.
  stormAt: SCENARIO === "storm" ? seconds(env("STORM_RAMP", "5m")) + seconds(env("STORM_WAIT", "2m")) : null,
  pollPath: env("POLL_PATH", ""),
}
if (settings.dwellMax < settings.dwellMin) throw new Error("DWELL_MAX_S must not be below DWELL_MIN_S")
if (["first", "every"].indexOf(settings.assets) === -1) throw new Error("ASSETS must be first or every")

// The phase a moment falls in: the run's own phases, and otherwise the
// scenario's name, so every figure can be read per phase.
export function phaseAt(now) {
  for (let i = 0; i < PHASES.length; i++) if (now >= PHASES[i].from && now < PHASES[i].to) return PHASES[i].name
  return PHASES.length ? (now < PHASES[0].from ? "warmup" : "after") : SCENARIO
}

// A visitor's whole stay can run past the last stage; a VU leaving the
// ramp-down finishes its page rather than being cut off mid-visit, so no
// close at the end of a run is counted as a drop.
const graceful = `${settings.dwellMax + 60}s`

function rampingPages(target, ramp, hold, down, extra) {
  return Object.assign(
    {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: ramp, target },
        { duration: hold, target },
        { duration: down, target: 0 },
      ],
      gracefulRampDown: graceful,
      gracefulStop: graceful,
    },
    extra || {},
  )
}

function scenarios() {
  switch (SCENARIO) {
    case "smoke":
      return { smoke: rampingPages(integer("PAGES", 5), "30s", "1m", "10s") }
    case "ramp":
      return { ramp: rampingPages(PAGES, RAMP, HOLD, RAMP_DOWN) }
    case "spike": {
      const spike = {
        spike: rampingPages(integer("SPIKE_PAGES", 500), env("SPIKE_IN", "30s"), env("SPIKE_HOLD", "5m"), "1m", {
          startTime: env("SPIKE_AFTER", "0s"),
        }),
      }
      const base = integer("SPIKE_BASE", 0)
      if (base > 0) spike.spike_base = rampingPages(base, "2m", "10m", "1m")
      return spike
    }
    case "storm":
      return {
        storm: rampingPages(PAGES, env("STORM_RAMP", "5m"), `${seconds(env("STORM_WAIT", "2m")) + seconds(env("STORM_AFTER", "5m"))}s`, "1m"),
      }
    case "deploy":
      return { deploy: rampingPages(PAGES, RAMP, env("DEPLOY_HOLD", "20m"), RAMP_DOWN) }
    case "faults": {
      const total = Math.ceil((PHASES[PHASES.length - 1].to - Date.now()) / 1000)
      return {
        faults: {
          executor: "ramping-vus",
          startVUs: 0,
          stages: [
            { duration: "30s", target: integer("FAULT_PAGES", 200) },
            { duration: `${Math.max(total - 30, 1)}s`, target: integer("FAULT_PAGES", 200) },
          ],
          gracefulRampDown: graceful,
          gracefulStop: graceful,
        },
      }
    }
    default:
      throw new Error(`SCENARIO must be smoke, ramp, spike, storm, deploy or faults, got ${SCENARIO}`)
  }
}

// Each scenario's pass mark. Every run keeps Sean's targets. A connection the
// site drops is never expected except in the deploy run, where a single
// machine's replacement drops every connection once by design: there the bar
// is that every page comes back (lv_rejoin_lost), which is what "zero lost
// connections during a deploy" means for a visitor. In the storm the drops are
// the test's own, and every page must come back the same way.
function thresholds() {
  const marks = Object.assign({}, TARGETS, { lv_rejoin_lost: ["count==0"] })
  // While the machine is replaced in the deploy run, every reconnect attempt
  // fails until the new one answers, and every new visitor arriving in that
  // gap fails to load the page. Those failures are the gap, which local.sh
  // measures, so inside its deploy phase (the two minutes from the release
  // command on) they are measured, and before and after it they are judged.
  // Anywhere else a socket that never opens is a page that never came alive.
  if (SCENARIO === "deploy") {
    delete marks.http_req_failed
    marks["http_req_failed{phase:before}"] = ["rate<0.001"]
    marks["http_req_failed{phase:deploy}"] = ["rate>=0"]
    marks["http_req_failed{phase:after}"] = ["rate<0.001"]
  } else {
    marks.lv_socket_drops = ["count==0"]
    marks.lv_ws_connect_failed = ["count==0"]
  }
  if (SCENARIO !== "faults") return marks

  // Per phase: pages keep answering (a page saying it couldn't be loaded
  // counts as answering), and the live connection keeps joining. The ">=0"
  // marks pass always; they are there so the summary carries each phase's
  // figure, which k6 exports only for a metric with a threshold.
  const phased = { lv_rejoin_lost: ["count==0"] }
  for (const { name } of PHASES) {
    phased[`http_req_failed{kind:page,phase:${name}}`] = ["rate<0.001"]
    phased[`lv_join_errors{phase:${name}}`] = ["rate<0.001"]
    phased[`http_req_duration{kind:page,phase:${name}}`] = ["p(95)>=0"]
    phased[`lv_join_duration{phase:${name}}`] = ["p(95)>=0"]
    phased[`page_degraded{phase:${name}}`] = ["rate>=0"]
    phased[`lv_socket_drops{phase:${name}}`] = ["count>=0"]
  }
  return phased
}

export function buildOptions() {
  return {
    scenarios: scenarios(),
    thresholds: thresholds(),
    // A page that redirects is a finding, never a hop to somewhere else.
    maxRedirects: 0,
    userAgent:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 keyfleet-visitors/1",
    setupTimeout: "2m",
    summaryTrendStats: ["avg", "min", "med", "max", "p(90)", "p(95)", "p(99)", "count"],
    // The scenario and the target ride on every figure, so a summary says
    // what it measured.
    tags: { target: site.base },
  }
}
