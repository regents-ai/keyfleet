import {afterEach, expect, it, vi} from "vitest"

afterEach(() => {
  vi.unstubAllGlobals()
  vi.resetModules()
})

// Costly failure: a page with a long address loses its error reports, which
// go over the size the site reads (KeyfleetWeb.Router's visit report limit,
// 22 KiB).
it("sends at most 20 lines naming the page by 1,024 characters, which fit the site's limit", async () => {
  const listeners = new Map<string, () => void>()
  const sent: string[] = []

  vi.stubGlobal("window", {
    location: {pathname: "/keys/" + "9".repeat(5000)},
    addEventListener: (event: string, listener: () => void) => listeners.set(event, listener),
    setTimeout: () => 1,
    clearTimeout: () => undefined,
  })
  vi.stubGlobal("document", {addEventListener: () => undefined, querySelector: () => null})
  vi.stubGlobal("fetch", (_url: string, init: {body: string}) => {
    sent.push(init.body)
    return Promise.resolve()
  })

  const {installVisitLog} = await import("../js/visit_log")
  installVisitLog()
  for (let n = 0; n < 25; n++) listeners.get("unhandledrejection")?.()
  listeners.get("pagehide")?.()

  expect(sent).toHaveLength(1)
  const {lines} = JSON.parse(sent[0]) as {lines: {where: string}[]}
  expect(lines).toHaveLength(20)
  expect(lines.every(line => line.where === "/keys/" + "9".repeat(1018))).toBe(true)
  expect(new TextEncoder().encode(sent[0]).length).toBeLessThanOrEqual(22 * 1024)
})
