// Visitors' own page timings, the Core Web Vitals, sent to this site once as
// the page is first hidden or left, and counted there into histograms with
// nothing saved (KeyfleetWeb.Vitals). A report carries the page's route
// pattern, never its address, the device class and the connection type the
// browser gives: no person, address or Key.
//
// The measuring library comes in its own small file, fetched only once the
// page has loaded and the browser is idle, so it never competes with the
// page's first paint or its first answers to a press. It reads the timings
// the browser kept from before it arrived, so nothing is lost by waiting.

import type {Metric} from "web-vitals"

type Report = {
  route: string
  device: "phone" | "desktop"
  connection?: string
  metrics: Partial<Record<Metric["name"], number>>
}

// The same 48rem at which the site's layout leaves its phone form.
const desktop = "(min-width: 48rem)"

export function installVitals(): void {
  // The server writes the pattern only on the site's own pages. A browser a
  // program drives, such as a test, a Lighthouse run or a crawler, is not a
  // visitor, so it reports nothing.
  const route = document.querySelector<HTMLMetaElement>('meta[name="vitals-route"]')?.content
  if (!route || navigator.webdriver || typeof navigator.sendBeacon !== "function") return

  const report: Report = {
    route,
    device: window.matchMedia(desktop).matches ? "desktop" : "phone",
    metrics: {},
  }
  // Only Chromium browsers say what kind of connection they are on.
  const connection = (navigator as Navigator & {connection?: {effectiveType?: string}}).connection
    ?.effectiveType
  if (connection) report.connection = connection

  // Whole milliseconds, and the layout shift score to four places, keep the
  // report small without changing what the histograms can tell apart.
  const keep = ({name, value}: Metric) => {
    report.metrics[name] = name === "CLS" ? Math.round(value * 10_000) / 10_000 : Math.round(value)
  }

  // One report a page view: the first time the page is hidden or left, with
  // what has been measured by then. A visit that comes back to the tab and
  // carries on is reported as it stood when it was first hidden.
  let sent = false
  const send = () => {
    if (sent || Object.keys(report.metrics).length === 0) return
    sent = true
    navigator.sendBeacon("/vitals", JSON.stringify(report))
  }

  whenIdleAfterLoad(() => {
    import("web-vitals")
      .then(({onCLS, onFCP, onINP, onLCP, onTTFB}) => {
        for (const on of [onCLS, onFCP, onINP, onLCP, onTTFB]) on(keep)
        // After the library's own listeners, so what it settles as the page
        // is hidden is already in the report.
        document.addEventListener("visibilitychange", () => {
          if (document.visibilityState === "hidden") send()
        })
        // Safari does not always say the page is hidden as it is left.
        window.addEventListener("pagehide", send)
      })
      // A library that could not be fetched, such as one a deploy has just
      // replaced, costs this page's report and nothing else.
      .catch(() => undefined)
  })
}

// Safari has no idle callback, so a second's wait stands in for one.
function whenIdleAfterLoad(run: () => void) {
  const idle = () =>
    typeof requestIdleCallback === "function" ? requestIdleCallback(run, {timeout: 5000}) : setTimeout(run, 1000)

  if (document.readyState === "complete") idle()
  else window.addEventListener("load", idle, {once: true})
}
