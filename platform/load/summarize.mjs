#!/usr/bin/env node
// Turns k6 runs into Markdown tables of target, measured and pass or fail.
//
//   node platform/load/summarize.mjs results/ramp-<time>/ramp.json [more.json ...]
//   node platform/load/summarize.mjs --faults results/faults-<time>
//
// Each summary is k6's --summary-export JSON. When the server's metrics were
// scraped beside it (metrics/start.prom and end.prom, as local.sh writes
// them), the table adds the wait for a database connection between the two.
// A faults run's folder is what faults.sh writes: faults.json, phases.json,
// probes.tsv, container.tsv and metrics/<phase>.{start,end}.prom. It exits 1
// when anything failed, so a script can stop on it. Node only, no packages.

import { existsSync, readFileSync } from "node:fs"
import { basename, dirname, join } from "node:path"

// What each figure is, in words, and how it is written.
const LABELS = {
  http_req_failed: ["Requests that failed (pages and their files)", "rate"],
  "http_req_duration{kind:page}": ["Page drawn by the server (dead render)", "time"],
  http_req_duration: ["Every request", "time"],
  lv_join_errors: ["Live joins that failed", "rate"],
  lv_join_duration: ["Live join, request to reply", "time"],
  lv_socket_drops: ["Open connections the site dropped", "count"],
  lv_ws_connect_failed: ["Connection attempts that never opened", "count"],
  lv_rejoin_lost: ["Pages that never came back after a drop", "count"],
  lv_page_ready: ["First request to a live page", "time"],
  lv_ws_connecting: ["Socket handshake", "time"],
  lv_rejoin_duration: ["Drop to rejoined", "time"],
  lv_rejoins: ["Pages that rejoined after a drop", "count"],
  lv_storm_drops: ["Connections dropped by the storm", "count"],
  lv_join_reloads: ["Joins refused as stale (page reloaded)", "count"],
  lv_phx_errors: ["Live views that crashed (phx_error)", "count"],
  lv_phx_close: ["Live views the site closed (phx_close)", "count"],
  lv_redirects: ["Pages the site sent elsewhere", "count"],
  lv_heartbeat_rtt: ["Heartbeat round trip", "time"],
  lv_heartbeat_timeouts: ["Heartbeats unanswered for 30 s", "count"],
  lv_longpoll_fallback: ["Pages a browser would move to long polling (2.5 s)", "rate"],
  lv_event_errors: ["Hook events answered with an error", "count"],
  lv_join_reply_bytes: ["Join reply size", "bytes"],
  lv_event_reply_bytes: ["Hook event reply size (key map, sea)", "bytes"],
  page_html_bytes: ["Page HTML size (uncompressed)", "bytes"],
  page_degraded: ["Pages saying they couldn't be loaded", "rate"],
  page_failed: ["Page loads that failed", "count"],
  data_received: ["Data received by the load generator", "bytes_total"],
  vus_max: ["Open pages at most (VUs)", "count"],
  iterations: ["Visits", "count"],
}

// Figures shown after the targets when a run has them, with no pass mark.
const INFO = [
  ["http_req_failed", "rate"],
  ["lv_socket_drops", "count"],
  ["lv_page_ready", "p(95)"],
  ["lv_ws_connecting", "p(95)"],
  ["lv_rejoins", "count"],
  ["lv_rejoin_duration", "p(95)"],
  ["lv_rejoin_duration", "max"],
  ["lv_storm_drops", "count"],
  ["lv_ws_connect_failed", "count"],
  ["lv_join_reloads", "count"],
  ["lv_phx_errors", "count"],
  ["lv_phx_close", "count"],
  ["lv_redirects", "count"],
  ["lv_heartbeat_rtt", "p(95)"],
  ["lv_heartbeat_timeouts", "count"],
  ["lv_longpoll_fallback", "rate"],
  ["lv_event_errors", "count"],
  ["page_degraded", "rate"],
  ["page_failed", "count"],
  ["page_html_bytes", "avg"],
  ["lv_join_reply_bytes", "avg"],
  ["lv_event_reply_bytes", "p(95)"],
  ["data_received", "count"],
  ["vus_max", "max"],
  ["iterations", "count"],
]

function kindOf(name) {
  const base = name.replace(/\{.*\}$/, "")
  return (LABELS[name] || LABELS[base] || [null, base.endsWith("_bytes") ? "bytes" : "count"])[1]
}

function labelOf(name) {
  const base = name.replace(/\{.*\}$/, "")
  if (LABELS[name]) return LABELS[name][0]
  const tags = (/\{(.*)\}$/.exec(name) || [, ""])[1]
  return LABELS[base] ? `${LABELS[base][0]}${tags ? ` (${tags})` : ""}` : name
}

// Two decimals at most, with no trailing zeros: 1 s, 1.5 s, 0.1%.
function trim(value, places) {
  return String(Number(value.toFixed(places)))
}

function ms(value) {
  return value >= 1000 ? `${trim(value / 1000, 2)} s` : `${Math.round(value)} ms`
}

function bytes(value) {
  if (value >= 1e9) return `${(value / 1e9).toFixed(2)} GB`
  if (value >= 1e6) return `${(value / 1e6).toFixed(1)} MB`
  if (value >= 1e3) return `${(value / 1e3).toFixed(1)} KB`
  return `${Math.round(value)} B`
}

function percent(value) {
  return `${trim(value * 100, value < 0.01 ? 3 : 2)}%`
}

// One figure of a metric, from either summary format k6 writes.
function figure(metric, aggregate) {
  const values = metric.values || metric
  if (aggregate === "rate") return values.rate !== undefined ? values.rate : values.value
  if (aggregate === "count" && values.count === undefined) return values.passes !== undefined ? values.passes : undefined
  return values[aggregate]
}

function write(name, aggregate, value) {
  if (value === undefined || value === null) return "not measured"
  const kind = kindOf(name)
  const prefix = /^p\(|^max$|^avg$|^med$/.test(aggregate) ? `${aggregate.replace(/^p\((\d+)\)$/, "p$1")} ` : ""
  if (kind === "rate" || aggregate === "rate") return percent(value)
  if (kind === "time") return prefix + ms(value)
  if (kind === "bytes" || kind === "bytes_total") return prefix + bytes(value)
  return prefix + String(Math.round(value))
}

function target(name, expression) {
  const match = /^\s*([a-z]+(?:\([\d.]+\))?)\s*(<=|>=|===|==|!=|<|>)\s*([\d.]+)\s*$/.exec(expression)
  if (!match) return { aggregate: null, words: expression, info: false }
  const [, aggregate, op, raw] = match
  const limit = Number(raw)
  if (op === ">=" && limit === 0) return { aggregate, words: "measured", info: true }
  const kind = kindOf(name)
  const value =
    kind === "rate" || aggregate === "rate"
      ? percent(limit)
      : kind === "time"
        ? ms(limit)
        : kind.startsWith("bytes")
          ? bytes(limit)
          : String(limit)
  const words = op === "==" || op === "===" ? `= ${value}` : `${op} ${value}`
  return { aggregate, words: `${aggregate === "count" || aggregate === "rate" ? "" : `${aggregate.replace(/^p\((\d+)\)$/, "p$1")} `}${words}`, info: false }
}

// Whether a threshold held: the old format writes true for a crossed one, the
// new one writes ok.
function held(result) {
  return typeof result === "boolean" ? !result : Boolean(result && result.ok)
}

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"))
}

function table(rows) {
  const lines = ["| Measure | Target | Measured | Result |", "| --- | --- | --- | --- |"]
  for (const row of rows) lines.push(`| ${row.measure} | ${row.target} | ${row.measured} | ${row.result} |`)
  return lines.join("\n")
}

function summaryRows(summary) {
  const rows = []
  const judged = new Set()
  let failed = false
  const metrics = summary.metrics || {}
  const names = Object.keys(metrics).sort()
  for (const name of names) {
    const thresholds = metrics[name].thresholds || (metrics[name].values && metrics[name].values.thresholds) || {}
    for (const expression of Object.keys(thresholds)) {
      const goal = target(name, expression)
      if (goal.info) continue
      const ok = held(thresholds[expression])
      if (!ok) failed = true
      judged.add(name)
      rows.push({
        measure: labelOf(name),
        target: goal.words,
        measured: write(name, goal.aggregate, figure(metrics[name], goal.aggregate)),
        result: ok ? "pass" : "**FAIL**",
      })
    }
  }
  for (const [name, aggregate] of INFO) {
    if (!metrics[name] || judged.has(name)) continue
    const value = figure(metrics[name], aggregate)
    if (value === undefined) continue
    rows.push({ measure: labelOf(name), target: "measured", measured: write(name, aggregate, value), result: "" })
  }
  return { rows, failed }
}

// --- the faults run ---

function readTsv(path) {
  if (!existsSync(path)) return []
  return readFileSync(path, "utf8")
    .split("\n")
    .filter((line) => line.trim() !== "")
    .map((line) => line.split("\t"))
}

// A Prometheus text histogram's buckets, summed over every label set.
function buckets(path, name) {
  if (!existsSync(path)) return null
  const counts = {}
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const match = new RegExp(`^${name}_bucket\\{(.*)\\}\\s+([\\d.eE+-]+)$`).exec(line)
    if (!match) continue
    const le = /le="([^"]+)"/.exec(match[1])
    if (!le) continue
    counts[le[1]] = (counts[le[1]] || 0) + Number(match[2])
  }
  return counts
}

// histogram_quantile over the change between two scrapes.
function quantile(q, start, end) {
  if (!start || !end) return null
  const bounds = Object.keys(end)
    .map((le) => [le === "+Inf" ? Infinity : Number(le), (end[le] || 0) - (start[le] || 0)])
    .sort((a, b) => a[0] - b[0])
  const total = bounds.length ? bounds[bounds.length - 1][1] : 0
  if (total <= 0) return null
  const rank = q * total
  let lowerBound = 0
  let lowerCount = 0
  for (const [bound, count] of bounds) {
    if (count >= rank) {
      if (bound === Infinity) return lowerBound
      return lowerBound + ((bound - lowerBound) * (rank - lowerCount)) / Math.max(count - lowerCount, 1e-9)
    }
    lowerBound = bound
    lowerCount = count
  }
  return lowerBound
}

function seconds(value) {
  return value === null ? "no queries" : value >= 1 ? `${value.toFixed(2)} s` : `${Math.round(value * 1000)} ms`
}

// Pages answer and the site stays one process throughout; health answers
// within Fly's two-second check, only ever "ok" or "unavailable"; it says
// what its phase expects; and after a fault the site is whole within 30 s.
function faultsReport(dir) {
  const summary = readJson(join(dir, "faults.json"))
  const metrics = summary.metrics || {}
  const phases = readJson(join(dir, "phases.json"))
  const probes = readTsv(join(dir, "probes.tsv")).map(([at, healthStatus, healthMs, healthBody, pageStatus, pageMs, pageDegraded]) => ({
    at: Number(at),
    healthStatus,
    healthMs: Number(healthMs),
    healthBody,
    pageStatus,
    pageMs: Number(pageMs),
    pageDegraded: pageDegraded === "1",
  }))
  const container = readTsv(join(dir, "container.tsv"))
  let failed = false

  const lines = [
    "| Phase | What is done | Pages answered (k6) | Pages showing they couldn't load | Live joins failed | Page p95 | Health answers | Health as designed | DB wait p95 / p99 | Recovered in | Result |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
  ]
  for (const phase of phases) {
    const inPhase = probes.filter((p) => p.at >= phase.from && p.at < phase.to)
    const k6 = (name) => metrics[`${name}{${name.startsWith("http_req") ? "kind:page," : ""}phase:${phase.name}}`]
    const answered = k6("http_req_failed")
    const failedRate = answered ? figure(answered, "rate") : null
    const pageOk = failedRate !== null && failedRate < 0.001 && inPhase.every((p) => p.pageStatus === "200")
    const joins = k6("lv_join_errors")
    const joinRate = joins ? figure(joins, "rate") : null
    const joinOk = joinRate === null || joinRate < 0.001
    const degradedMetric = metrics[`page_degraded{phase:${phase.name}}`]
    const pageP95 = metrics[`http_req_duration{kind:page,phase:${phase.name}}`]

    const okCount = inPhase.filter((p) => p.healthStatus === "200" && p.healthBody === "ok").length
    const unavailable = inPhase.filter((p) => p.healthStatus === "503" && p.healthBody === "unavailable")
    const other = inPhase.length - okCount - unavailable.length
    const slowest = inPhase.reduce((max, p) => Math.max(max, p.healthMs), 0)
    let healthOk = other === 0 && slowest < 2000 && inPhase.length > 0
    if (phase.health === "ok") healthOk = healthOk && okCount === inPhase.length
    if (phase.health === "unavailable") healthOk = healthOk && unavailable.length > 0 && unavailable[0].at - phase.from <= 10000

    let recovered = ""
    let recoveryOk = true
    if (phase.kind === "recover") {
      // Whole again: three answers in a row with health ok and the page drawn
      // without saying it couldn't be loaded.
      let run = 0
      let at = null
      for (const p of inPhase) {
        const whole = p.healthBody === "ok" && p.pageStatus === "200" && !p.pageDegraded
        run = whole ? run + 1 : 0
        if (whole && run === 1) at = p.at
        if (run >= 3) break
      }
      recoveryOk = run >= 3 && at - phase.from <= 30000
      recovered = run >= 3 ? `${((at - phase.from) / 1000).toFixed(1)} s` : "not within the phase"
    }

    const db = [
      quantile(0.95, buckets(join(dir, "metrics", `${phase.name}.start.prom`), "health_db_queue_seconds"), buckets(join(dir, "metrics", `${phase.name}.end.prom`), "health_db_queue_seconds")),
      quantile(0.99, buckets(join(dir, "metrics", `${phase.name}.start.prom`), "health_db_queue_seconds"), buckets(join(dir, "metrics", `${phase.name}.end.prom`), "health_db_queue_seconds")),
    ]

    const ok = pageOk && joinOk && healthOk && recoveryOk
    if (!ok) failed = true
    lines.push(
      `| ${phase.name} | ${phase.does} | ${failedRate === null ? "no loads" : `${percent(1 - failedRate)} answered`}${inPhase.some((p) => p.pageStatus !== "200") ? ", probe saw an error" : ""} | ${degradedMetric ? percent(figure(degradedMetric, "rate")) : "-"} | ${joinRate === null ? "no joins" : percent(joinRate)} | ${pageP95 ? ms(figure(pageP95, "p(95)")) : "-"} | ${okCount} ok, ${unavailable.length} unavailable, ${other} other; slowest ${ms(slowest)} | ${healthOk ? "yes" : "**no**"} (${phase.health}) | ${seconds(db[0])} / ${seconds(db[1])} | ${recovered} | ${ok ? "pass" : "**FAIL**"} |`,
    )
  }

  const started = new Set(container.map((row) => row[2]))
  const running = container.every((row) => row[1] === "true")
  const restarts = container.reduce((max, row) => Math.max(max, Number(row[3] || 0)), 0)
  const steady = running && started.size === 1 && restarts === 0 && container.length > 0
  if (!steady) failed = true

  const lost = metrics.lv_rejoin_lost ? figure(metrics.lv_rejoin_lost, "count") : 0
  if (lost > 0) failed = true

  const text = [
    `## Faults run: ${basename(dir)}`,
    "",
    lines.join("\n"),
    "",
    `- The server process stayed up through every phase: ${steady ? "yes" : `**no** (running at every check: ${running}, start times seen: ${started.size}, restarts: ${restarts})`}.`,
    `- Pages whose connection dropped and never came back: ${lost}.`,
    "- Pass: every page load answers (a page saying it couldn't be loaded counts as an answer, a 5xx does not), live joins keep succeeding, health answers within 2 s with \"ok\" or \"unavailable\" and says what the phase expects, the site is whole within 30 s of a fault ending, and the process never restarts.",
  ].join("\n")
  return { text, failed }
}

// The wait for a database connection (the pool of five) between two scrapes of
// one server's metrics: the whole run, and in a deploy run the replacement
// server's own from its start.
function poolRows(dir) {
  const rows = []
  for (const [from, to, words] of [
    ["start", "end", ""],
    ["after-start", "after-end", ", replacement server"],
  ]) {
    const start = buckets(join(dir, `${from}.prom`), "health_db_queue_seconds")
    const end = buckets(join(dir, `${to}.prom`), "health_db_queue_seconds")
    if (!start || !end) continue
    rows.push({
      measure: `Wait for a database connection, p95 / p99 (server metrics${words})`,
      target: "measured",
      measured: `${seconds(quantile(0.95, start, end))} / ${seconds(quantile(0.99, start, end))}`,
      result: "",
    })
  }
  return rows
}

function main(args) {
  let failed = false
  const parts = []
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--faults") {
      const result = faultsReport(args[++i])
      parts.push(result.text)
      failed = failed || result.failed
      continue
    }
    const path = args[i]
    const summary = readJson(path)
    const { rows, failed: runFailed } = summaryRows(summary)
    rows.push(...poolRows(join(dirname(path), "metrics")))
    const duration = summary.state && summary.state.testRunDurationMs ? ` (${(summary.state.testRunDurationMs / 60000).toFixed(1)} min)` : ""
    parts.push([`## ${basename(path, ".json")}${duration}`, "", table(rows), "", runFailed ? "Result: **FAIL**" : "Result: pass"].join("\n"))
    failed = failed || runFailed
  }
  if (parts.length === 0) {
    console.error("usage: summarize.mjs <summary.json>... [--faults <run folder>]")
    process.exit(2)
  }
  console.log(parts.join("\n\n"))
  process.exit(failed ? 1 : 0)
}

main(process.argv.slice(2))
