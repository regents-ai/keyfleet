import {expect, it} from "vitest"

import {localTime} from "../js/hooks/local_time"

// Sean's evening in New York, 20 October 2026 at 8:03 pm, is 00:03 on the
// 21st in UTC (21 October 2026: "It's 8:03 pm in NYC, so it'd be good if each
// message showed the user's local timezone").
const newYork = {locale: "en-US", timeZone: "America/New_York"}
const utc = {locale: "en-GB", timeZone: "UTC"}
const now = new Date("2026-10-21T00:05:00Z")

it("writes a message's time on the reader's own clock", () => {
  const at = new Date("2026-10-21T00:03:00Z")

  expect(localTime(at, now, "clock", newYork)).toBe("8:03 PM")
  expect(localTime(at, now, "clock", utc)).toBe("00:03")
  expect(localTime(at, now, "stamp", newYork)).toBe("20 October 2026 at 8:03 PM")
  expect(localTime(at, now, "date", newYork)).toBe("20 Oct 2026")
})

it("splits today from yesterday by the reader's own calendar", () => {
  // 23:30 UTC on the 20th is yesterday by UTC but still today in New York.
  const lastNight = new Date("2026-10-20T23:30:00Z")
  expect(localTime(lastNight, now, "moment", newYork)).toBe("Today 7:30 PM")
  expect(localTime(lastNight, now, "moment", utc)).toBe("Yesterday 23:30")
  expect(localTime(lastNight, now, "clock", utc)).toBe("Yesterday")

  // 02:00 UTC on the 20th was still the 19th in New York.
  const early = new Date("2026-10-20T02:00:00Z")
  expect(localTime(early, now, "moment", newYork)).toBe("Yesterday 10:00 PM")
  expect(localTime(early, now, "moment", utc)).toBe("Yesterday 02:00")

  expect(localTime(new Date("2026-10-18T12:00:00Z"), now, "moment", newYork)).toBe("18 Oct")
  expect(localTime(new Date("2025-12-31T12:00:00Z"), now, "clock", newYork)).toBe("31 Dec 2025")
})
