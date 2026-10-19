// One visitor's page, from the first request to leaving: the dead render, the
// files it loads, then the live connection the browser keeps open while the
// visitor reads. The connection speaks what phoenix 1.8.15 and
// phoenix_live_view 1.2.12 (platform/mix.lock) speak, the JSON serializer
// vsn 2.0.0: every message is [join_ref, ref, topic, event, payload].
//
// It does what their client does, so the server sees what a browser makes it
// do: it joins every root live view on the page (the page itself, and the
// harbour's sea on the product pages), sends the events the page's hooks send
// on mount, heartbeats every 30 seconds, reconnects with the client's own
// backoff when the connection drops, rejoins a crashed view, and reloads the
// page when a join is refused as stale.

import http from "k6/http"
import { sleep } from "k6"
import { WebSocket } from "k6/websockets"
import { setTimeout, clearTimeout, setInterval, clearInterval } from "k6/timers"
import { Counter, Rate, Trend } from "k6/metrics"
import exec from "k6/execution"

import { degraded, fetchAssets, getPage, htmlBytes, parse } from "./page.js"
import { phaseAt, settings, site } from "./config.js"

const m = {
  pageReady: new Trend("lv_page_ready", true),
  wsConnecting: new Trend("lv_ws_connecting", true),
  wsConnectFailed: new Counter("lv_ws_connect_failed"),
  joinDuration: new Trend("lv_join_duration", true),
  joinErrors: new Rate("lv_join_errors"),
  joinReplyBytes: new Trend("lv_join_reply_bytes"),
  joinReloads: new Counter("lv_join_reloads"),
  eventDuration: new Trend("lv_event_duration", true),
  eventReplyBytes: new Trend("lv_event_reply_bytes"),
  eventErrors: new Counter("lv_event_errors"),
  diffs: new Counter("lv_diffs"),
  phxErrors: new Counter("lv_phx_errors"),
  phxClose: new Counter("lv_phx_close"),
  redirects: new Counter("lv_redirects"),
  heartbeatRtt: new Trend("lv_heartbeat_rtt", true),
  heartbeatTimeouts: new Counter("lv_heartbeat_timeouts"),
  longPollFallback: new Rate("lv_longpoll_fallback"),
  socketDrops: new Counter("lv_socket_drops"),
  stormDrops: new Counter("lv_storm_drops"),
  rejoins: new Counter("lv_rejoins"),
  rejoinDuration: new Trend("lv_rejoin_duration", true),
  rejoinLost: new Counter("lv_rejoin_lost"),
  pageFailed: new Counter("page_failed"),
}

// The client's own timings (phoenix socket.js and LiveView's constants.ts).
const HEARTBEAT_MS = 30000
const PUSH_TIMEOUT_MS = 10000
const LONGPOLL_FALLBACK_MS = 2500 // app.ts sets longPollFallbackMs: 2500
const MAX_RELOADS = 10
const reconnectAfter = (tries) => [10, 50, 100, 150, 200, 250, 500, 1000, 2000][tries - 1] || 5000
const rejoinAfter = (tries) => [1000, 2000, 5000][tries - 1] || 10000
const reloadJitter = () => 5000 + Math.random() * 5000

// Assets are kept per VU, as a browser's cache keeps them per visitor.
let assetsFetched = false

function tagsFor(page, extra) {
  return Object.assign({ page: page.name, phase: phaseAt(Date.now()) }, extra || {})
}

// Opens `page` as a new visitor and keeps it open until `leaveAt`. `carried`
// is what a reload of the same page brings with it: how many reloads in a row
// there have been, and when its connection dropped if it has not come back.
export function visit(page, leaveAt, carried) {
  const state = carried || { reloads: 0, droppedAt: null }
  const started = Date.now()
  if (!carried) http.cookieJar().clear(site.base)

  // Every count a threshold reads exists from the start, so an untouched one
  // reads 0 rather than missing.
  m.socketDrops.add(0, tagsFor(page))
  m.wsConnectFailed.add(0, tagsFor(page))
  m.rejoinLost.add(0, tagsFor(page))

  const res = getPage(site, page, { phase: phaseAt(started) })
  if (res.status !== 200) {
    m.pageFailed.add(1, tagsFor(page, { status: String(res.status) }))
    // A reload that fails leaves the visitor on an error page with nothing to
    // reconnect: the page is lost.
    if (state.droppedAt !== null) m.rejoinLost.add(1, tagsFor(page))
    // A new visitor who meets an error waits a few seconds before trying
    // again, rather than asking again at once.
    else if (!carried) sleep(5 + Math.random() * 5)
    return
  }

  const html = String(res.body)
  htmlBytes.add(html.length, tagsFor(page))
  const dom = parse(html)
  degraded.add(dom.degraded, tagsFor(page))

  if (!dom.csrf || !dom.views.some((view) => view.main)) {
    m.pageFailed.add(1, tagsFor(page, { status: "no_live_page" }))
    if (!carried) sleep(5 + Math.random() * 5)
    return
  }

  if (settings.assets === "every" || !assetsFetched) {
    fetchAssets(site, dom.assets, { phase: phaseAt(Date.now()) })
    assetsFetched = true
  }

  new LivePage(page, dom, sessionCookie(res), started, leaveAt, state).start()
}

// The cookies this page load set, as the Cookie header its socket sends. The
// session cookie is Secure (__Host-keyfleet), which a browser sends to
// http://localhost but k6's cookie jar never sends over plain HTTP, so the
// socket carries it by hand; without it the socket's CSRF check fails and
// every join is refused as stale.
function sessionCookie(res) {
  const pairs = []
  for (const name of Object.keys(res.cookies || {})) {
    const cookie = res.cookies[name][0]
    if (cookie) pairs.push(`${name}=${cookie.value}`)
  }
  return pairs.join("; ")
}

class LivePage {
  constructor(page, dom, cookie, started, leaveAt, state) {
    this.page = page
    this.dom = dom
    this.cookie = cookie
    this.started = started
    this.leaveAt = leaveAt
    this.state = state
    this.url = site.base + page.path
    this.path = page.path.split("?")[0]
    this.socketUrl = `${site.wsBase}/live/websocket?_csrf_token=${encodeURIComponent(dom.csrf)}&vsn=2.0.0`
    this.tracked = dom.tracked.map((path) => site.base + path)
    this.views = dom.views.map((view) =>
      Object.assign({}, view, { topic: `lv:${view.id}`, joinRef: null, pendingJoin: null, joined: false, mounts: 0, attempts: 0, tries: 0, timer: null }),
    )
    this.ref = 0
    this.ws = null
    this.opened = false
    this.everOpened = false
    this.ready = false
    this.leaving = false
    this.leaveWhenBack = false
    this.reconnectTries = 0
    this.heartbeat = null
    this.events = {}
    this.timers = {}
  }

  tags(extra) {
    return tagsFor(this.page, extra)
  }

  nextRef() {
    this.ref += 1
    return String(this.ref)
  }

  timer(name, ms, fn) {
    if (this.timers[name]) clearTimeout(this.timers[name])
    this.timers[name] = setTimeout(() => {
      delete this.timers[name]
      fn()
    }, ms)
  }

  cancel(name) {
    if (this.timers[name]) clearTimeout(this.timers[name])
    delete this.timers[name]
  }

  start() {
    this.timer("dwell", Math.max(this.leaveAt - Date.now(), 0), () => this.leave())
    if (settings.stormAt !== null) {
      const at = exec.scenario.startTime + settings.stormAt * 1000
      if (at > Date.now() && at < this.leaveAt) this.timer("storm", at - Date.now(), () => this.storm())
    }
    if (this.state.droppedAt !== null) this.watchDeadline()
    this.connect()
  }

  connect() {
    const began = Date.now()
    const ws = new WebSocket(this.socketUrl, null, {
      headers: { Origin: site.origin, Cookie: this.cookie },
      tags: this.tags({ name: "live_socket" }),
    })
    ws.binaryType = "arraybuffer"
    this.ws = ws
    this.opened = false

    // The browser gives the socket 2.5 s to open and answer a ping, then
    // falls back to long polling for the rest of the visit. That fallback is
    // counted here; this visitor stays on the socket either way.
    const first = !this.everOpened
    if (first) this.timer("fallback", LONGPOLL_FALLBACK_MS, () => this.judgeFallback(true))

    ws.onopen = () => {
      if (ws !== this.ws) return
      this.opened = true
      this.everOpened = true
      this.reconnectTries = 0
      m.wsConnecting.add(Date.now() - began, this.tags())
      this.sendHeartbeat(first)
      this.views.forEach((view) => this.join(view))
      this.heartbeat = setInterval(() => this.beat(), HEARTBEAT_MS)
    }
    ws.onmessage = (event) => {
      if (ws === this.ws && typeof event.data === "string") this.receive(event.data)
    }
    // The close that always follows an error decides what happens next.
    ws.onerror = () => {}
    ws.onclose = (event) => {
      if (ws === this.ws) this.closed(event || {})
    }
  }

  send(message) {
    if (this.ws && this.opened) this.ws.send(JSON.stringify(message))
  }

  judgeFallback(fellBack) {
    if (this.fallbackJudged) return
    this.fallbackJudged = true
    this.cancel("fallback")
    m.longPollFallback.add(fellBack, this.tags())
  }

  sendHeartbeat(probe) {
    const ref = this.nextRef()
    this.pendingHeartbeat = { ref, sent: Date.now(), probe }
    this.send([null, ref, "phoenix", "heartbeat", {}])
  }

  // A heartbeat still unanswered when the next is due means the connection is
  // dead to the client, which closes it and reconnects.
  beat() {
    if (!this.pendingHeartbeat) return this.sendHeartbeat(false)
    m.heartbeatTimeouts.add(1, this.tags())
    this.abandon({ code: "heartbeat_timeout" })
  }

  // Lets go of the open connection as the client does when it gives up on
  // it: the page goes on as if it had closed, and the socket's own close,
  // whenever it comes, is ignored.
  abandon(event) {
    const ws = this.ws
    this.ws = null
    if (ws) ws.close(event.code === "storm" ? 4000 : 1000)
    this.closed(event)
  }

  join(view) {
    const ref = this.nextRef()
    view.joinRef = ref
    view.pendingJoin = { ref, sent: Date.now(), rejoin: view.mounts > 0 }
    const params = { _csrf_token: this.dom.csrf, _mounts: view.mounts, _mount_attempts: view.attempts }
    if (this.tracked.length > 0) params._track_static = this.tracked
    view.attempts += 1
    this.send([
      ref,
      ref,
      view.topic,
      "phx_join",
      { url: view.sticky ? undefined : this.url, params, session: view.session, static: view.static, sticky: view.sticky },
    ])
    this.cancel(`join:${view.id}`)
    this.timer(`join:${view.id}`, PUSH_TIMEOUT_MS, () => {
      if (view.pendingJoin && view.pendingJoin.ref === ref) this.joinFailed(view, "timeout")
    })
  }

  // A hook's pushEvent on mount: the view's own topic, a reply expected.
  pushEvent(view, event, value) {
    const ref = this.nextRef()
    this.events[ref] = { name: event, sent: Date.now() }
    this.send([view.joinRef, ref, view.topic, "event", { type: "hook", event, value }])
  }

  receive(data) {
    let message
    try {
      message = JSON.parse(data)
    } catch (_error) {
      return
    }
    const [joinRef, ref, topic, event, payload] = message

    if (topic === "phoenix") {
      if (event === "phx_reply" && this.pendingHeartbeat && ref === this.pendingHeartbeat.ref) {
        const rtt = Date.now() - this.pendingHeartbeat.sent
        m.heartbeatRtt.add(rtt, this.tags())
        if (this.pendingHeartbeat.probe) this.judgeFallback(rtt > LONGPOLL_FALLBACK_MS)
        this.pendingHeartbeat = null
      }
      return
    }

    const view = this.views.find((candidate) => candidate.topic === topic)
    // Anything for a join this page has since replaced is stale.
    if (!view || (joinRef !== null && joinRef !== view.joinRef)) return

    switch (event) {
      case "phx_reply":
        if (view.pendingJoin && ref === view.pendingJoin.ref) this.joinReplied(view, payload, data.length)
        else if (this.events[ref]) this.eventReplied(ref, payload, data.length)
        return
      case "diff":
        m.diffs.add(1, this.tags())
        return
      case "phx_error":
        // The view's process crashed: the client rejoins it on the same
        // connection, after its own backoff.
        m.phxErrors.add(1, this.tags({ view: view.main ? "main" : "other" }))
        view.joined = false
        view.tries += 1
        this.timer(`rejoin:${view.id}`, rejoinAfter(view.tries), () => {
          if (this.opened && !this.leaving) this.join(view)
        })
        return
      case "phx_close":
        m.phxClose.add(1, this.tags({ view: view.main ? "main" : "other" }))
        view.joined = false
        return
      case "redirect":
      case "live_redirect":
        // The server sent the visitor elsewhere: this page's visit ends.
        m.redirects.add(1, this.tags())
        this.leave()
        return
      default:
        return
    }
  }

  joinReplied(view, reply, bytes) {
    const pending = view.pendingJoin
    view.pendingJoin = null
    this.cancel(`join:${view.id}`)
    const response = (reply && reply.response) || {}

    if (reply && reply.status === "ok") {
      view.joined = true
      view.mounts += 1
      view.tries = 0
      const tags = this.tags({ view: view.main ? "main" : "other", rejoin: String(pending.rejoin) })
      m.joinDuration.add(Date.now() - pending.sent, tags)
      m.joinErrors.add(false, tags)
      m.joinReplyBytes.add(bytes, tags)
      this.mounted(view)
      return
    }

    // A refused session or a changed route sends the browser to load the
    // page afresh (view.ts, onJoinError), which is not a failure by itself.
    if (["stale", "unauthorized", "reload"].indexOf(response.reason) !== -1) {
      m.joinReloads.add(1, this.tags({ reason: response.reason }))
      this.reload(0)
      return
    }
    this.joinFailed(view, response.redirect || response.live_redirect ? "redirect" : response.reason || "error")
  }

  joinFailed(view, reason) {
    view.pendingJoin = null
    m.joinErrors.add(true, this.tags({ view: view.main ? "main" : "other", reason }))
    // A main view that cannot join reloads the page after 5 to 10 seconds.
    if (view.main) this.reload(reloadJitter())
  }

  // What the page does once a view is joined: the page is ready when its main
  // view is, and the hooks that speak on mount speak.
  mounted(view) {
    if (view.main) {
      if (!this.ready) {
        this.ready = true
        if (this.state.reloads === 0) m.pageReady.add(Date.now() - this.started, this.tags())
        this.state.reloads = 0
      }
      if (this.state.droppedAt !== null) {
        m.rejoins.add(1, this.tags({ cause: this.state.cause || "drop" }))
        m.rejoinDuration.add(Date.now() - this.state.droppedAt, this.tags({ cause: this.state.cause || "drop" }))
        this.state.droppedAt = null
        this.cancel("deadline")
        if (this.leaveWhenBack) {
          this.leave()
          return
        }
      }
      if (this.dom.keyMap) this.pushEvent(view, "keymap_ready", {})
    } else if (!view.sticky) {
      // The harbour's sea learns which page is on show (hooks/harbour_sea.ts).
      this.pushEvent(view, "show_page", { path: this.path })
    }
  }

  eventReplied(ref, reply, bytes) {
    const sent = this.events[ref]
    delete this.events[ref]
    const tags = this.tags({ event: sent.name })
    m.eventDuration.add(Date.now() - sent.sent, tags)
    m.eventReplyBytes.add(bytes, tags)
    if (!reply || reply.status !== "ok") m.eventErrors.add(1, tags)
  }

  closed(event) {
    const wasOpen = this.opened
    this.opened = false
    if (this.heartbeat) clearInterval(this.heartbeat)
    this.heartbeat = null
    this.pendingHeartbeat = null
    this.views.forEach((view) => {
      view.joined = false
      view.pendingJoin = null
      this.cancel(`join:${view.id}`)
      this.cancel(`rejoin:${view.id}`)
    })
    if (this.leaving) return

    // A drop is an open connection lost; an attempt that never opened is
    // counted on its own, since every reconnect while the site is away is one.
    if (event.code === "storm") m.stormDrops.add(1, this.tags())
    else if (wasOpen) m.socketDrops.add(1, this.tags({ code: String(event.code || "none") }))
    else m.wsConnectFailed.add(1, this.tags())
    this.dropped(event.code === "storm" ? "storm" : "drop")
  }

  // The connection is gone without the visitor leaving: reconnect as the
  // client does, and count the page lost if it is not back in time.
  dropped(cause) {
    if (this.state.droppedAt === null) {
      this.state.droppedAt = Date.now()
      this.state.cause = cause
      this.watchDeadline()
    }
    this.reconnectTries += 1
    this.timer("reconnect", reconnectAfter(this.reconnectTries), () => {
      if (!this.leaving) this.connect()
    })
  }

  watchDeadline() {
    const left = this.state.droppedAt + settings.rejoinDeadlineMs - Date.now()
    this.timer("deadline", Math.max(left, 0), () => {
      if (this.state.droppedAt === null) return
      m.rejoinLost.add(1, this.tags({ cause: this.state.cause || "drop" }))
      this.state.droppedAt = null
      this.leave()
    })
  }

  // Every open page drops its connection at the same moment, as a network
  // blip or an edge restart would drop it, and reconnects at once.
  storm() {
    if (this.opened && !this.leaving) this.abandon({ code: "storm" })
  }

  // Loads the page afresh after `delay`, as window.location does, carrying any
  // drop that is not yet healed. Ten reloads in a row is where the client
  // stops (MAX_RELOADS).
  reload(delay) {
    const state = this.state
    const page = this.page
    const leaveAt = this.leaveAt
    this.leave(true)
    // A page given up on while its connection is down never came back.
    if (state.reloads >= MAX_RELOADS) {
      if (state.droppedAt !== null) m.rejoinLost.add(1, this.tags({ cause: state.cause || "drop" }))
      return
    }
    state.reloads += 1
    // A page still waiting for its connection is reloaded even when the
    // visitor's time is up, so its drop is judged like any other (leave()).
    setTimeout(() => {
      if (Date.now() < leaveAt || state.droppedAt !== null) visit(page, leaveAt, state)
    }, delay)
  }

  // The visitor leaves. While the connection is down the page stays until it
  // comes back or is counted lost, so a drop near the end of a visit is still
  // judged.
  leave(reloading) {
    if (this.leaving) return
    if (!reloading && this.state.droppedAt !== null) {
      this.leaveWhenBack = true
      this.cancel("dwell")
      this.cancel("storm")
      return
    }
    this.leaving = true
    Object.keys(this.timers).forEach((name) => this.cancel(name))
    if (this.heartbeat) clearInterval(this.heartbeat)
    this.heartbeat = null
    if (this.ws) this.ws.close(1000)
  }
}
