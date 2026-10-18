import {afterEach, expect, it, vi} from "vitest"
import {reconnectWaits, spreadReconnect} from "../js/reconnect"

// Costly failure: after a deploy every open page reconnects in the same
// instant, or waits far longer than Phoenix would, or never stops waiting.
afterEach(() => vi.restoreAllMocks())

const waitFor = (tries: number) => reconnectWaits[tries - 1] ?? 5000

it("each wait stays between half and one and a half times Phoenix's own", () => {
  for (let tries = 1; tries <= reconnectWaits.length + 3; tries++) {
    const wait = waitFor(tries)
    for (let draw = 0; draw < 200; draw++) {
      const spread = spreadReconnect(tries)
      expect(spread).toBeGreaterThanOrEqual(Math.round(wait / 2))
      expect(spread).toBeLessThanOrEqual(Math.round(wait * 1.5))
    }
  }
})

it("reaches both ends of the spread, and waits 5 seconds once Phoenix's list runs out", () => {
  vi.spyOn(Math, "random").mockReturnValue(0)
  expect(spreadReconnect(1)).toBe(5)
  expect(spreadReconnect(reconnectWaits.length + 1)).toBe(2500)

  vi.spyOn(Math, "random").mockReturnValue(0.999999)
  expect(spreadReconnect(reconnectWaits.length)).toBe(3000)
  expect(spreadReconnect(50)).toBe(7500)
})

it("spreads a crowd: a thousand pages at the same attempt don't all come back together", () => {
  // Attempt 8 waits 500 to 1500 ms: ten tenths of a second, about 100 pages each.
  const byTenth = new Map<number, number>()
  for (let page = 0; page < 1000; page++) {
    const tenth = Math.floor(spreadReconnect(8) / 100)
    byTenth.set(tenth, (byTenth.get(tenth) ?? 0) + 1)
  }
  expect(Math.max(...byTenth.values())).toBeLessThan(300)
})
