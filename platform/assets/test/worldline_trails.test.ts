import {describe, expect, it} from "vitest"

import {
  MAX_EVENTS,
  POINT_FLOATS,
  SEGMENT_FLOATS,
  lay,
  nearest,
  pack,
  project,
  shape,
  type View,
  type WorldEvent,
} from "../js/worldline/trails"

const ANCHOR = Date.UTC(2026, 10, 12, 12)
const view: View = {left: -3600, perPx: 3600 / 1000, width: 1000, height: 600}

const event = (id: string, secondsAgo: number, trail: string, kind = "change"): WorldEvent => ({
  id,
  at: ANCHOR - secondsAgo * 1000,
  trail,
  kind,
  who: "Key 7",
  what: "Change",
  title: id,
  path: `/classic/1/${id}`,
  live: true,
})

// A fleet's history: three main trails, two rooms and the line's points,
// spread over a day with bursts, as a seeded run always draws it.
const history = (count: number): WorldEvent[] => {
  const trails = ["workspace", "code", "notebooks", "room:general", "room:people", "line"]
  let seed = 7
  const next = () => (seed = (seed * 1_103_515_245 + 12_345) % 2_147_483_648) / 2_147_483_648
  return Array.from({length: count}, (_, i) => {
    const trail = trails[Math.floor(next() * trails.length)]
    const kind = trail.startsWith("room:") ? "post" : trail === "line" ? "poll" : "change"
    return event(`e${i}`, Math.floor(next() * 86_400), trail, kind)
  })
}

const shuffled = <T>(items: readonly T[]) => {
  const copy = [...items]
  let seed = 3
  for (let i = copy.length - 1; i > 0; i--) {
    seed = (seed * 16_807) % 2_147_483_647
    const j = seed % (i + 1)
    ;[copy[i], copy[j]] = [copy[j], copy[i]]
  }
  return copy
}

const thetas = (events: readonly WorldEvent[], anchor = ANCHOR) =>
  new Map(lay(events, anchor).placed.map(point => [point.event.id, point.theta]))

describe("laying out a Worldline", () => {
  it("lays the same events out the same way whatever order they come in", () => {
    const events = history(400)
    const first = pack(lay(events, ANCHOR))
    const again = pack(lay(shuffled(events), ANCHOR))

    expect(again.segments).toEqual(first.segments)
    expect(again.points).toEqual(first.points)
  })

  it("draws only the line and its head with no events", () => {
    const layout = lay([], ANCHOR)
    const {segments, points} = pack(layout)

    expect(layout.trails).toEqual([])
    expect(layout.placed).toEqual([])
    expect(segments.length).toBe(SEGMENT_FLOATS)
    expect(points.length).toBe(POINT_FLOATS)
  })

  it("draws one event as one stretch on to now and one mark", () => {
    const layout = lay([event("only", 60, "workspace")], ANCHOR)
    const {segments, points} = pack(layout)

    expect(layout.trails.map(trail => trail.name)).toEqual(["workspace"])
    expect(layout.placed[0]).toMatchObject({t: -60, theta: 0})
    expect(segments.length).toBe(2 * SEGMENT_FLOATS)
    // The stretch starts and ends at the event, and runs on to now.
    expect([...segments.slice(SEGMENT_FLOATS, SEGMENT_FLOATS + 4)]).toEqual([-60, 0, -60, 0])
    expect(segments[2 * SEGMENT_FLOATS - 1]).toBe(1)
    expect(points.length).toBe(2 * POINT_FLOATS)
    expect(points[POINT_FLOATS + 8]).toBe(0)
  })

  it("keeps every mark where it was as older events are read and newer ones arrive", () => {
    const events = history(600)
    const before = thetas(events)
    const older = Array.from({length: 120}, (_, i) =>
      event(`old${i}`, 90_000 + i * 37, ["workspace", "code", "room:general"][i % 3]),
    )
    const newer = [event("new1", -5, "workspace"), event("new2", -9, "room:general", "post")]
    const after = thetas([...older, ...events, ...newer])

    for (const [id, theta] of before) expect(after.get(id)).toBe(theta)
    // Older marks turn back from the anchor, newer ones on from it.
    expect(after.get("old0")).toBeLessThan(0)
    expect(after.get("new1")).toBeGreaterThan(0)
  })

  it("gives a room's trail a shape from its name alone", () => {
    const general = shape("room:general")

    expect(shape("room:general")).toEqual(general)
    expect(shape("room:people")).not.toEqual(general)
    // Every room keeps inside the three main trails, and its loops lean.
    const inner = Math.min(...["notebooks", "workspace", "code"].map(name => shape(name).radius))
    for (const name of ["room:general", "room:people", "room:a", "room:日本語"]) {
      const room = shape(name)
      expect(room.radius).toBeGreaterThan(0)
      expect(room.radius).toBeLessThan(inner)
      expect(room.tilt).toBeGreaterThan(0)
      expect(room.tilt).toBeLessThan(Math.PI / 2)
    }
  })

  it("packs as many events as the picture holds, every float finite", () => {
    const events = history(MAX_EVENTS)
    const layout = lay(events, ANCHOR)
    const {segments, points} = pack(layout)
    const stretches = layout.trails.filter(trail => trail.name !== "line").reduce((n, trail) => n + trail.knots.length, 0)

    expect(layout.placed).toHaveLength(MAX_EVENTS)
    expect(segments.length).toBe((1 + stretches) * SEGMENT_FLOATS)
    expect(points.length).toBe((1 + MAX_EVENTS) * POINT_FLOATS)
    expect(segments.every(Number.isFinite)).toBe(true)
    expect(points.every(Number.isFinite)).toBe(true)
    // Each mark carries its index in `placed`, which is how the focus finds it.
    expect(points[MAX_EVENTS * POINT_FLOATS + 8]).toBe(MAX_EVENTS - 1)
  })
})

describe("pointing at a mark", () => {
  it("finds the mark under the pointer, and none far from every mark", () => {
    const layout = lay(history(2_000), ANCHOR)
    const target = layout.placed.findIndex(point => point.t > view.left + 600 && point.event.trail === "code")
    const at = project(layout.placed[target].t, layout.placed[target].theta, layout.placed[target].shape, view, 0.4)

    const found = nearest(layout.placed, view, 0.4, at.x, at.y, 24)
    const point = layout.placed[found!]
    const there = project(point.t, point.theta, point.shape, view, 0.4)

    expect(Math.hypot(there.x - at.x, there.y - at.y)).toBe(0)
    expect(nearest(layout.placed, view, 0.4, -5_000, -5_000, 24)).toBeUndefined()
  })

  it("puts the line's own points on the middle of the picture", () => {
    const layout = lay([event("poll", 1_800, "line", "poll")], ANCHOR)
    const point = layout.placed[0]
    const at = project(point.t, point.theta, point.shape, view, 1.3)

    expect(at).toEqual({x: 500, y: 300, near: 0})
  })
})
