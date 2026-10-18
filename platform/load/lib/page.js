// A page as a browser first meets it: the HTML the server draws before any
// connection (the dead render), what that HTML says to connect with, and the
// files it loads.

import http from "k6/http"
import { Rate, Trend } from "k6/metrics"

export const htmlBytes = new Trend("page_html_bytes")
// A page drawn saying it couldn't be loaded (KeyfleetWeb.Components.LoadFailed)
// or that its figures aren't showing. It still answered, which is what the
// faults run asks of it, so this is counted apart from failures.
export const degraded = new Rate("page_degraded")

const DEGRADED = /couldn(?:’|'|&#39;)t be loaded|aren(?:’|'|&#39;)t showing right now/

// Every file a page loads is fetched with the headers a browser sends; the
// server answers the precompressed copy (Plug.Static, gzip: true).
const ACCEPT = {
  page: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
  asset: "*/*",
}
const HEADERS = { "Accept-Language": "en-US,en;q=0.9", "Accept-Encoding": "gzip, deflate, br, zstd" }

function each(re, text, fn) {
  re.lastIndex = 0
  let match
  while ((match = re.exec(text)) !== null) fn(match)
}

function unescape(value) {
  return value
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&")
}

function attr(tag, name) {
  const match = new RegExp(`\\s${name}="([^"]*)"`).exec(tag)
  return match ? unescape(match[1]) : null
}

function flag(tag, name) {
  return new RegExp(`\\s${name}(?:[\\s=>/]|$)`).test(tag)
}

// A same-origin path, never a full address to some other site.
function local(path) {
  return path && path.charAt(0) === "/" && path.charAt(1) !== "/" ? path : null
}

// What the dead render says: the CSRF token the socket presents, each live
// view to join (a root view only: a nested one joins from its parent's
// render, and these pages have none), the files tracked for a new release,
// the files the page loads, and which of the page's hooks talk to the server
// as soon as they mount.
export function parse(html) {
  const meta = /<meta[^>]*\sname="csrf-token"[^>]*>/.exec(html)
  const views = []
  each(/<[a-zA-Z][^>]*\sdata-phx-session="[^"]*"[^>]*>/g, html, ([tag]) => {
    if (flag(tag, "data-phx-parent-id")) return
    views.push({
      id: attr(tag, "id"),
      session: attr(tag, "data-phx-session"),
      static: attr(tag, "data-phx-static") || null,
      main: flag(tag, "data-phx-main"),
      sticky: flag(tag, "data-phx-sticky"),
    })
  })

  const tracked = []
  const assets = []
  each(/<(link|script|img)\s[^>]*>/g, html, ([tag, name]) => {
    const href = local(attr(tag, name === "link" ? "href" : "src"))
    if (!href) return
    if (flag(tag, "phx-track-static")) tracked.push(href)
    const rel = attr(tag, "rel") || ""
    if (name === "script" && attr(tag, "type") === "module") assets.push({ path: href, kind: "js" })
    else if (name === "link" && rel === "stylesheet") assets.push({ path: href, kind: "css" })
    else if (name === "link" && rel === "preload") assets.push({ path: href, kind: attr(tag, "as") || "preload" })
    else if (name === "link" && rel === "icon" && attr(tag, "type") === "image/svg+xml") assets.push({ path: href, kind: "icon" })
    else if (name === "img") assets.push({ path: href, kind: "img" })
  })

  return {
    csrf: meta ? attr(meta[0], "content") : null,
    views,
    tracked,
    assets,
    keyMap: /\sphx-hook="KeyMap"/.test(html),
    degraded: DEGRADED.test(html),
  }
}

export function getPage(site, page, tags) {
  return http.get(site.base + page.path, {
    headers: Object.assign({ Accept: ACCEPT.page }, HEADERS),
    tags: Object.assign({ kind: "page", name: page.name, page: page.name }, tags),
  })
}

// The modules a script imports before it runs. esbuild writes them as
// `from"./chunks/x.js"` or `import"./chunks/x.js"`; an `import(...)` is
// loaded only when the page asks for it, as the key map's stage is.
const STATIC_IMPORT = /(?:\bfrom\s*|\bimport\s*)["'](\.\.?\/[\w./-]+\.js)["']/g

function resolve(from, relative) {
  const parts = from.split("?")[0].split("/").slice(0, -1)
  for (const part of relative.split("/")) {
    if (part === "..") parts.pop()
    else if (part !== ".") parts.push(part)
  }
  return parts.join("/")
}

// Fetches what the page loads, six at a time as a browser does per host, then
// every module the scripts import, level by level.
export function fetchAssets(site, assets, tags) {
  const seen = {}
  let level = assets.filter((asset) => !seen[asset.path] && (seen[asset.path] = true))
  for (let depth = 0; level.length > 0 && depth < 8; depth++) {
    const responses = http.batch(
      level.map((asset) => ({
        method: "GET",
        url: site.base + asset.path,
        params: {
          headers: Object.assign({ Accept: ACCEPT.asset }, HEADERS),
          responseType: asset.kind === "js" ? "text" : "none",
          tags: Object.assign({ kind: "asset", name: `asset:${asset.kind}` }, tags),
        },
      })),
    )
    const next = []
    responses.forEach((res, i) => {
      if (level[i].kind !== "js" || res.status !== 200) return
      each(STATIC_IMPORT, String(res.body), ([, relative]) => {
        const path = resolve(level[i].path, relative)
        if (!seen[path] && Object.keys(seen).length < 80) {
          seen[path] = true
          next.push({ path, kind: "js" })
        }
      })
    })
    level = next
  }
}
