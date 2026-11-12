import {describe, expect, it} from "vitest"

import {CARD, layout, type Clock, type Layout, type TreeItem, type TreeLink} from "../js/hooks/tree_canvas/layout"

const HOUR = 60 * 60 * 1000
const DAY = 24 * HOUR
const at = (iso: string) => Date.parse(iso)

// Hours and days in UTC, headed by their ISO date and hour, so the tests read
// the same in every time zone.
const utc: Clock = {
  start: (time, every) => (every === "day" ? Math.floor(time / DAY) * DAY : Math.floor(time / HOUR) * HOUR),
  label: (start, every) => new Date(start).toISOString().slice(0, every === "day" ? 10 : 13),
}

const item = (id: string, created: string, extra: Partial<TreeItem> = {}): TreeItem => ({
  id,
  created: at(created),
  changed: at(created),
  author: "Key 1",
  ...extra,
})

const link = (from: string, to: string, type = "produces"): TreeLink => ({id: `${from}>${to}`, from, to, type})

const now = at("2026-11-12T12:00:00Z")

const card = (laid: Layout, id: string) => laid.cards.get(id)!

const overlapping = (laid: Layout) => {
  const all = [...laid.cards.values()]
  return all.flatMap((a, i) =>
    all
      .slice(i + 1)
      .filter(
        b =>
          a.x < b.x + CARD.width && b.x < a.x + CARD.width && a.y < b.y + CARD.height && b.y < a.y + CARD.height,
      )
      .map(b => [a.id, b.id]),
  )
}

describe("tree canvas layout", () => {
  it("slices by the hour, oldest on the left, each headed with its hour", () => {
    const items = [
      item("a", "2026-11-12T10:05:00Z"),
      item("b", "2026-11-12T10:40:00Z"),
      item("c", "2026-11-12T11:20:00Z"),
    ]
    const laid = layout(items, [], "time", "hour", now, utc)

    expect(laid.slices.map(slice => slice.label)).toEqual(["2026-11-12T10", "2026-11-12T11"])
    expect(card(laid, "a").x).toBe(card(laid, "b").x)
    expect(card(laid, "c").x).toBeGreaterThan(card(laid, "a").x + CARD.width)
    // The column of each slice lies inside its band.
    const [first, second] = laid.slices
    expect(card(laid, "a").x).toBeGreaterThanOrEqual(first.x)
    expect(card(laid, "c").x + CARD.width).toBeLessThanOrEqual(second.x + second.width)
    expect(overlapping(laid)).toEqual([])
  })

  it("slices by the day, and the same items by the hour make more slices", () => {
    const items = [
      item("a", "2026-11-10T09:00:00Z"),
      item("b", "2026-11-11T09:00:00Z"),
      item("c", "2026-11-11T18:00:00Z"),
      item("d", "2026-11-12T08:00:00Z"),
    ]
    const days = layout(items, [], "time", "day", now, utc)
    const hours = layout(items, [], "time", "hour", now, utc)

    expect(days.slices.map(slice => slice.label)).toEqual(["2026-11-10", "2026-11-11", "2026-11-12"])
    expect(hours.slices).toHaveLength(4)
    expect(days.order).toEqual(["a", "b", "c", "d"])
    expect(card(days, "a").x).toBeLessThan(card(days, "b").x)
    expect(card(days, "b").x).toBeLessThan(card(days, "d").x)
  })

  it("gives each Key a band, in the Keys' order, with the tree running across the bands", () => {
    const items = [
      item("goal", "2026-11-12T09:00:00Z", {author: "Key 12"}),
      item("task", "2026-11-12T10:00:00Z", {author: "Key 2"}),
      item("note", "2026-11-12T11:00:00Z", {author: "Key 12"}),
    ]
    const laid = layout(items, [link("goal", "task", "implements"), link("task", "note")], "author", "day", now, utc)

    expect(laid.slices.map(slice => slice.label)).toEqual(["Key 2", "Key 12"])
    expect(card(laid, "task").y).toBeLessThan(card(laid, "goal").y)
    expect(card(laid, "goal").x).toBeLessThan(card(laid, "task").x)
    expect(card(laid, "task").x).toBeLessThan(card(laid, "note").x)
    // Each card stands inside its own band.
    for (const [id, slice] of [["task", 0], ["goal", 1], ["note", 1]] as const) {
      const band = laid.slices[slice]
      expect(card(laid, id).y).toBeGreaterThanOrEqual(band.y)
      expect(card(laid, id).y + CARD.height).toBeLessThanOrEqual(band.y + band.height)
    }
    expect(overlapping(laid)).toEqual([])
  })

  it("bands items by how recently they changed, the most recent at the top", () => {
    const items = [
      item("old", "2026-09-01T00:00:00Z"),
      item("week", "2026-11-08T00:00:00Z"),
      item("hour", "2026-11-12T11:30:00Z"),
      item("day", "2026-11-12T01:00:00Z"),
    ]
    const laid = layout(items, [], "activity", "day", now, utc)

    expect(laid.slices.map(slice => slice.label)).toEqual(["Past hour", "Past day", "Past week", "Older"])
    expect(laid.order).toEqual(["hour", "day", "week", "old"])
    expect(card(laid, "hour").y).toBeLessThan(card(laid, "day").y)
    expect(card(laid, "week").y).toBeLessThan(card(laid, "old").y)
  })

  it("stands every item after what it came from and before what was made from it", () => {
    const items = [
      item("root", "2026-11-12T09:00:00Z"),
      item("left", "2026-11-12T09:10:00Z"),
      item("right", "2026-11-12T09:20:00Z"),
      item("leaf", "2026-11-12T09:30:00Z"),
      item("alone", "2026-11-12T09:40:00Z"),
    ]
    const links = [link("root", "left"), link("root", "right"), link("left", "leaf"), link("right", "leaf")]

    for (const arrange of ["time", "author", "activity"] as const) {
      const laid = layout(items, links, arrange, "day", now, utc)
      for (const {from, to} of links) expect(card(laid, from).x).toBeLessThan(card(laid, to).x)
      expect(laid.paths.every(path => !path.back)).toBe(true)
      expect(overlapping(laid)).toEqual([])
    }

    // A path leaves the right of the card it comes from for the left of the next.
    const laid = layout(items, links, "time", "day", now, utc)
    const [x1, y1, , , , , x2, y2] = laid.paths[0].points
    expect([x1, y1]).toEqual([card(laid, "root").x + CARD.width, card(laid, "root").y + CARD.height / 2])
    expect([x2, y2]).toEqual([card(laid, "left").x, card(laid, "left").y + CARD.height / 2])
  })

  it("cuts a loop where it returns to its oldest item, and still draws that link", () => {
    const items = [
      item("a", "2026-11-12T09:00:00Z"),
      item("b", "2026-11-12T09:10:00Z"),
      item("c", "2026-11-12T09:20:00Z"),
    ]
    const links = [link("a", "b"), link("b", "c"), link("c", "a")]
    const laid = layout(items, links, "author", "day", now, utc)

    expect(laid.paths.map(path => [path.id, path.back])).toEqual([
      ["a>b", false],
      ["b>c", false],
      ["c>a", true],
    ])
    expect(card(laid, "a").x).toBeLessThan(card(laid, "b").x)
    expect(card(laid, "b").x).toBeLessThan(card(laid, "c").x)
    expect(laid.order).toEqual(["a", "b", "c"])
  })

  it("leaves out links to items it was not given, and links from an item to itself", () => {
    const laid = layout([item("a", "2026-11-12T09:00:00Z")], [link("a", "gone"), link("a", "a")], "time", "day", now, utc)
    expect(laid.paths).toEqual([])
  })

  it("lays out nothing for no items", () => {
    const laid = layout([], [], "time", "day", now, utc)
    expect(laid.cards.size).toBe(0)
    expect(laid.slices).toEqual([])
    expect(laid.order).toEqual([])
    expect(laid.bounds).toEqual({left: 0, top: 0, right: 0, bottom: 0})
  })

  it("lays out a single item at the origin, in one slice", () => {
    for (const arrange of ["time", "author", "activity"] as const) {
      const laid = layout([item("only", "2026-11-12T09:00:00Z")], [], arrange, "hour", now, utc)
      expect(card(laid, "only")).toMatchObject({x: 0, y: 0})
      expect(laid.slices).toHaveLength(1)
      expect(laid.order).toEqual(["only"])
    }
  })

  it("lays out many items, linked every which way, with no card on another", () => {
    // A fixed sequence, so the test reads the same every run.
    let seed = 7
    const random = () => (seed = (seed * 16807) % 2147483647) / 2147483647
    const items = Array.from({length: 150}, (_, i) =>
      item(`item${i}`, new Date(at("2026-11-01T00:00:00Z") + Math.floor(random() * 11 * DAY)).toISOString(), {
        author: `Key ${1 + Math.floor(random() * 9)}`,
        changed: at("2026-09-01T00:00:00Z") + Math.floor(random() * 72 * DAY),
      }),
    )
    const links = Array.from({length: 600}, (_, i) =>
      link(`item${Math.floor(random() * 150)}`, `item${Math.floor(random() * 150)}`, i % 7 ? "produces" : "forks"),
    )

    for (const arrange of ["time", "author", "activity"] as const) {
      for (const every of ["hour", "day"] as const) {
        const laid = layout(items, links, arrange, every, now, utc)
        expect(laid.cards.size).toBe(150)
        expect(new Set(laid.order).size).toBe(150)
        expect(overlapping(laid)).toEqual([])
        if (arrange !== "time") {
          for (const path of laid.paths.filter(path => !path.back)) {
            expect(card(laid, path.from).x).toBeLessThan(card(laid, path.to).x)
          }
        }
        for (const placed of laid.cards.values()) {
          expect(placed.x).toBeGreaterThanOrEqual(laid.bounds.left)
          expect(placed.y + CARD.height).toBeLessThanOrEqual(laid.bounds.bottom)
        }
      }
    }
  })
})
