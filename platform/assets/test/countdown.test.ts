import {afterEach, beforeEach, expect, it, vi} from "vitest"

import {Countdown} from "../js/hooks/countdown"

// Vitest here runs without a document, so the countdown is the small surface
// the hook touches: its data attributes and its words.
function mount(dataset: Record<string, string>) {
  const hook = {el: {dataset, textContent: ""}}
  Countdown.mounted?.call(hook)
  return hook
}

beforeEach(() => {
  vi.useFakeTimers()
  vi.stubGlobal("window", globalThis)
})

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

it("counts down to the poll's close by the site's clock, even when the phone's clock is wrong", () => {
  // The phone's clock runs ten minutes behind the site's.
  vi.setSystemTime(1_000_000)
  const siteNow = 1_000_000 + 600_000
  const hook = mount({closesAt: String(siteNow + 61_500), now: String(siteNow), format: "seconds"})

  expect(hook.el.textContent).toBe("1:01 left")
  vi.advanceTimersByTime(1_500)
  expect(hook.el.textContent).toBe("1:00 left")
  vi.advanceTimersByTime(1_000)
  expect(hook.el.textContent).toBe("59 seconds left")
  vi.advanceTimersByTime(58_000)
  expect(hook.el.textContent).toBe("1 second left")
  vi.advanceTimersByTime(1_000)
  expect(hook.el.textContent).toBe("Closing…")

  // Once closed it waits for the page, with no timer left running.
  expect(vi.getTimerCount()).toBe(0)
})

it("writes the list's minutes in the page's own words", () => {
  vi.setSystemTime(0)
  const hook = mount({closesAt: String(120_000), now: "0", format: "minutes"})

  expect(hook.el.textContent).toBe("2 minutes left")
  vi.advanceTimersByTime(1_000)
  expect(hook.el.textContent).toBe("1 minute left")
  vi.advanceTimersByTime(60_000)
  expect(hook.el.textContent).toBe("Less than a minute left")
  expect(vi.getTimerCount()).toBe(0)
})

it("writes a proposal's hours, then its last hour in minutes", () => {
  vi.setSystemTime(0)
  const hook = mount({closesAt: String(7_200_000), now: "0", format: "hours"})

  expect(hook.el.textContent).toBe("2 hours left")
  vi.advanceTimersByTime(1_000)
  expect(hook.el.textContent).toBe("1 hour left")
  vi.advanceTimersByTime(3_600_000)
  expect(hook.el.textContent).toBe("59 minutes left")
  vi.advanceTimersByTime(3_540_000)
  expect(hook.el.textContent).toBe("Less than a minute left")
  expect(vi.getTimerCount()).toBe(0)
})

it("stops counting when the poll leaves the page", () => {
  vi.setSystemTime(0)
  const hook = mount({closesAt: String(30_000), now: "0", format: "seconds"})

  Countdown.destroyed?.call(hook)
  expect(vi.getTimerCount()).toBe(0)
})

it("counts a new Key's wait for the Treasury slice to the second, then says it is eligible", () => {
  vi.setSystemTime(0)
  const hook = mount({
    closesAt: String(172_800_000),
    now: "0",
    format: "clock",
    lead: "Eligible in",
    done: "Eligible",
  })

  expect(hook.el.textContent).toBe("Eligible in 48:00:00")
  vi.advanceTimersByTime(1_000)
  expect(hook.el.textContent).toBe("Eligible in 47:59:59")
  vi.advanceTimersByTime(172_798_000)
  expect(hook.el.textContent).toBe("Eligible in 00:00:01")
  vi.advanceTimersByTime(1_000)
  expect(hook.el.textContent).toBe("Eligible")
  expect(vi.getTimerCount()).toBe(0)
})
