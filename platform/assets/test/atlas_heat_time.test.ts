import {describe, expect, it} from "vitest"

import {
  LEVELS,
  bucketOf,
  dateOf,
  eachTick,
  hourOf,
  levelAt,
  msOf,
  nextContext,
  windowFor,
  windowOf,
} from "../js/atlas/heat/time"

const hourAt = (iso: string) => hourOf(Date.parse(iso))
const iso = (hour: number) => new Date(msOf(hour)).toISOString()

describe("the Atlas heat's time", () => {
  it("starts every week on a Monday at midnight UTC, as the page counts them", () => {
    // Friday 13 November 2026, mid-afternoon.
    const [start, end] = windowOf("week", hourAt("2026-11-13T15:20:00Z"))
    expect(iso(start)).toBe("2026-11-09T00:00:00.000Z")
    expect(iso(end)).toBe("2026-11-16T00:00:00.000Z")
    expect(new Date(msOf(start)).getUTCDay()).toBe(1)
  })

  it("names calendar months and years, however long", () => {
    expect(windowOf("month", hourAt("2024-02-29T23:00:00Z")).map(iso)).toEqual([
      "2024-02-01T00:00:00.000Z",
      "2024-03-01T00:00:00.000Z",
    ])
    expect(windowOf("year", hourAt("2026-11-13T00:00:00Z")).map(iso)).toEqual([
      "2026-01-01T00:00:00.000Z",
      "2027-01-01T00:00:00.000Z",
    ])
    expect(windowOf("day", hourAt("2025-12-31T23:59:00Z")).map(iso)).toEqual([
      "2025-12-31T00:00:00.000Z",
      "2026-01-01T00:00:00.000Z",
    ])
  })

  it("puts every tile on bucket boundaries, so tiles hold whole buckets", () => {
    for (const level of LEVELS) {
      expect(level.tile % level.hours).toBe(0)
      const start = bucketOf(hourAt("2026-07-04T10:00:00Z"), level.tile)
      expect(bucketOf(start, level.hours)).toBe(start)
    }
  })

  it("reads moments before the epoch into the buckets that hold them", () => {
    expect(iso(bucketOf(hourAt("2023-12-31T05:00:00Z"), 24))).toBe("2023-12-31T00:00:00.000Z")
    expect(dateOf(hourAt("2023-12-31T05:00:00Z"))).toBe("2023-12-31")
  })

  it("zooms from weeks to days to hours", () => {
    expect(levelAt(0.1)).toBe(0)
    expect(levelAt(0.5)).toBe(1)
    expect(levelAt(11.9)).toBe(1)
    expect(levelAt(12)).toBe(2)
    expect(levelAt(2400)).toBe(2)
  })

  it("reads a framed window back as the same window", () => {
    const at = hourAt("2026-11-13T12:00:00Z")
    for (const name of ["day", "week", "month", "year"] as const) {
      const [start, end] = windowOf(name, at)
      // A window framed across the screen shows a little more than itself.
      expect(windowFor((end - start) * 1.04)).toBe(name)
      expect(windowOf(name, (start + end) / 2)[0]).toBe(start)
    }
  })

  it("spaces the marks along the top so their words never crowd", () => {
    const marks: [number, string][] = []
    const from = hourAt("2026-11-13T00:00:00Z")
    eachTick(2, from, from + 24, 20, (hour, text) => marks.push([hour, text]))
    expect(marks[0]).toEqual([from, "13 Nov"])
    expect(marks[1][1]).toBe("03:00")
    for (let index = 1; index < marks.length; index++) expect((marks[index][0] - marks[index - 1][0]) * 20).toBeGreaterThanOrEqual(52)

    const months: string[] = []
    eachTick(0, hourAt("2025-11-01T00:00:00Z"), hourAt("2026-03-01T00:00:00Z"), 0.1, (_, text) => months.push(text))
    expect(months).toEqual(["Nov", "Dec", "2026", "Feb", "Mar"])
  })

  it("finds where the name at the left edge changes, a mark of its own at every level", () => {
    const at = hourAt("2025-12-31T22:30:00Z")
    expect([0, 1, 2].map(level => iso(nextContext(level, at)))).toEqual([
      "2026-01-01T00:00:00.000Z",
      "2026-01-01T00:00:00.000Z",
      "2026-01-01T00:00:00.000Z",
    ])
    expect(iso(nextContext(1, hourAt("2024-02-10T00:00:00Z")))).toBe("2024-03-01T00:00:00.000Z")
    expect(iso(nextContext(2, hourAt("2026-11-13T00:00:00Z")))).toBe("2026-11-14T00:00:00.000Z")

    // Each one is drawn as a mark, so the name it pushes away never hides it.
    for (const [level, zoom] of [[0, 0.1], [1, 2], [2, 20]]) {
      const marks: number[] = []
      eachTick(level, at, at + 24 * 40, zoom, hour => marks.push(hour))
      expect(marks).toContain(nextContext(level, at))
    }
  })
})
