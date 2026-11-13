import {describe, expect, it} from "vitest"

import {
  BEAD_FLOATS,
  BEAD_PERIOD,
  CURL_SHARE,
  MAX_EVENTS,
  POINT_FLOATS,
  QUIET,
  REACH,
  SEGMENT_FLOATS,
  SETTLE,
  across,
  along,
  beads,
  curlAt,
  lay,
  markAt,
  nearest,
  pack,
  project,
  riders,
  settled,
  shape,
  swirl,
  type View,
  type WorldEvent,
} from "../js/worldline/trails"

const ANCHOR = Date.UTC(2026, 10, 12, 12)
const view: View = {left: -3600, perPx: 3600 / 1000, width: 1000, height: 600, now: 0}

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

const placedById = (events: readonly WorldEvent[]) =>
  new Map(lay(events, ANCHOR).placed.map(point => [point.event.id, point]))

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

  it("draws one event as one stretch on to now, the line over it, and one mark under the head", () => {
    const layout = lay([event("only", 60, "workspace")], ANCHOR)
    const {segments, points} = pack(layout)

    expect(layout.trails.map(trail => trail.name)).toEqual(["workspace"])
    expect(layout.placed[0]).toMatchObject({t: -60, gap: QUIET})
    expect(segments.length).toBe(2 * SEGMENT_FLOATS)
    // The stretch starts and ends at the event, and runs on to now.
    expect([...segments.slice(0, 4)]).toEqual([-60, -60, QUIET, 0])
    expect(segments[11]).toBe(1)
    // The line comes after it.
    expect(segments[SEGMENT_FLOATS + 11]).toBe(2)
    expect(points.length).toBe(2 * POINT_FLOATS)
    // The mark carries its index, and the head comes after it.
    expect(points[10]).toBe(0)
    expect(points[POINT_FLOATS + 12]).toBe(2)
  })

  it("keeps every mark where it was as older events are read, and tightens only the newest curl as newer ones arrive", () => {
    const events = history(600)
    const before = placedById(events)
    const older = Array.from({length: 120}, (_, i) =>
      event(`old${i}`, 90_000 + i * 37, ["workspace", "code", "room:general"][i % 3]),
    )
    const newer = [event("new1", -5, "workspace"), event("new2", -9, "room:general", "post")]
    const read = placedById([...older, ...events])
    const arrived = placedById([...older, ...events, ...newer])

    for (const [id, point] of before) {
      expect(markAt(read.get(id)!, view, 0.4)).toEqual(markAt(point, view, 0.4))
      // Only each trail's newest takes a next event, and only on the two trails something arrived on.
      if (point.gap === QUIET && ["workspace", "room:general"].includes(point.event.trail)) {
        expect(arrived.get(id)!.gap).toBeLessThan(QUIET)
      } else {
        expect(markAt(arrived.get(id)!, view, 0.4)).toEqual(markAt(point, view, 0.4))
      }
    }
  })

  it("stands every mark in the same place whenever the page was read", () => {
    const events = history(300)
    const later = ANCHOR + 5_000_123
    const moved = (seconds: number): View => ({...view, left: view.left - seconds, now: view.now - seconds})
    const read = new Map(lay(events, later).placed.map(point => [point.event.id, point]))

    for (const point of lay(events, ANCHOR).placed) {
      const there = markAt(read.get(point.event.id)!, moved((later - ANCHOR) / 1000), 0.4)
      const here = markAt(point, view, 0.4)
      expect(there.x).toBeCloseTo(here.x, 6)
      expect(there.y).toBeCloseTo(here.y, 6)
    }
  })

  it("holds the newest events the picture has room for, without moving them", () => {
    const events = history(MAX_EVENTS)
    const more = Array.from({length: 50}, (_, i) => event(`older${i}`, 200_000 + i, "workspace"))
    const kept = lay([...events, ...more], ANCHOR)
    const alone = placedById(events)

    expect(kept.placed).toHaveLength(MAX_EVENTS)
    expect(kept.placed.some(point => point.event.id.startsWith("older"))).toBe(false)
    for (const point of kept.placed) {
      expect(markAt(point, view, 0.4)).toEqual(markAt(alone.get(point.event.id)!, view, 0.4))
    }
  })

  it("gives a room's trail a shape from its name alone", () => {
    const general = shape("room:general")

    expect(shape("room:general")).toEqual(general)
    expect(shape("room:people")).not.toEqual(general)
    // Every room runs inside the three main trails, its curls the smaller, and its loops lean.
    const inner = Math.min(...["notebooks", "workspace", "code"].map(name => shape(name).radius))
    for (const name of ["room:general", "room:people", "room:a", "room:日本語"]) {
      const room = shape(name)
      expect(room.radius).toBeGreaterThan(0)
      expect(room.radius).toBeLessThan(inner)
      expect(room.curl).toBeLessThan(shape("workspace").curl)
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
    expect(points[(MAX_EVENTS - 1) * POINT_FLOATS + 10]).toBe(MAX_EVENTS - 1)
  })
})

describe("curling at each event", () => {
  // A trail with a quiet spell, then a burst of a change every half minute,
  // all well before the trail settles into the head.
  const quietThenBurst = [
    event("q1", 3000, "workspace"),
    event("q2", 1800, "workspace"),
    ...Array.from({length: 8}, (_, i) => event(`b${i}`, 1200 - i * 30, "workspace")),
  ]
  const trail = () => lay(quietThenBurst, ANCHOR).trails[0]

  it("stands each event's mark on its trail at the tip of its curl, half a turn on and twice its width up", () => {
    const {knots} = trail()
    for (const knot of knots) {
      const coil = curlAt(knot.gap, knot.shape, view)
      const tip = knot.t + 0.5 * across(knot, coil, view) * view.perPx
      const mark = markAt(knot, view, 0.7)
      const there = along(trail(), tip, view, 0.7)!
      const beneath = project(tip, 0, 0, knot.shape, view, 0.7)

      expect(there.x).toBeCloseTo(mark.x, 9)
      expect(there.y).toBeCloseTo(mark.y, 9)
      expect(mark.x).toBeCloseTo(beneath.x, 9)
      expect(beneath.y - mark.y).toBeCloseTo(2 * coil, 9)
    }
  })

  it("loops each curl back on itself and back onto its trail before the next event", () => {
    const {knots} = trail()
    for (const knot of knots.slice(0, -1)) {
      const next = knots[knots.indexOf(knot) + 1]
      const coil = curlAt(knot.gap, knot.shape, view)
      const wide = across(knot, coil, view)
      const xs = Array.from({length: 81}, (_, i) => along(trail(), knot.t + (i / 80) * wide * view.perPx, view, 0)!.x)
      const end = knot.t + wide * view.perPx
      const back = along(trail(), end, view, 0)!
      const plain = project(end, 0, 0, knot.shape, view, 0)

      // The curl runs back against the line at its top, then on.
      expect(xs.some((x, i) => i > 0 && x < xs[i - 1])).toBe(true)
      expect(back.x).toBeCloseTo(plain.x, 9)
      expect(back.y).toBeCloseTo(plain.y, 9)
      expect(end).toBeLessThanOrEqual(next.t + 1e-9)
    }
    expect(swirl(0, 40)).toBe(0)
    expect(swirl(20, 40)).toBeCloseTo(Math.PI, 12)
    expect(swirl(40, 40)).toBeCloseTo(2 * Math.PI, 12)
    expect(swirl(90, 40)).toBeCloseTo(2 * Math.PI, 12)
  })

  it("curls a burst tighter than a quiet spell, and never past the trail's widest", () => {
    const {knots, shape: form} = trail()
    const widest = form.curl * REACH * view.height
    const quiet = curlAt(knots[0].gap, form, view)
    const burst = knots.slice(2, -1).map(knot => curlAt(knot.gap, form, view))

    expect(quiet).toBe(widest)
    for (const coil of burst) {
      expect(coil).toBe((CURL_SHARE * 30) / view.perPx)
      expect(coil).toBeLessThan(quiet)
    }
    // From far off the burst shows as one curl at its end, the trail's widest.
    expect(curlAt(knots.at(-1)!.gap, form, view)).toBe(widest)
    // Zoomed in, the burst's curls open up to the widest too.
    expect(curlAt(knots[3].gap, form, {...view, perPx: 0.05})).toBe(widest)
  })

  it("turns each trail at its own pace through time, the same however far it is drawn", () => {
    const form = shape("workspace")
    const at = (t: number) => project(t, 0, 0, form, {...view, now: 1e9}, 0)
    const around = at(-form.turn)
    const here = at(0)

    expect(around.y).toBeCloseTo(here.y, 6)
    expect(around.near).toBeCloseTo(here.near, 9)
    expect(at(-form.turn / 2).y).not.toBeCloseTo(here.y, 0)
    expect(new Set(["notebooks", "workspace", "code"].map(name => shape(name).turn)).size).toBe(3)
  })

  it("settles every trail into the head at now", () => {
    const into = SETTLE * view.width * view.perPx

    expect(settled(0, view)).toBe(0)
    expect(settled(-into / 2, view)).toBeCloseTo(0.5, 12)
    expect(settled(-into, view)).toBe(1)
    const head = along(trail(), -0.001, view, 0.9)!
    expect(head.out).toBeLessThan(0.001)
    expect(head.y).toBeCloseTo(view.height / 2, 1)
  })
})

describe("beads riding the trails", () => {
  const layout = lay(history(800), ANCHOR)
  const rows = (floats: Float32Array) =>
    Array.from({length: floats.length / BEAD_FLOATS}, (_, i) => [...floats.slice(i * BEAD_FLOATS, (i + 1) * BEAD_FLOATS)])

  it("rides the same beads at the same moment every time", () => {
    expect(beads(layout, view, 0.3, 42)).toEqual(beads(layout, view, 0.3, 42))
  })

  it("gives each trail its few beads, each on its trail", () => {
    const riding = rows(beads(layout, view, 0.3, 42))
    const most = layout.trails.reduce((n, trail) => n + trail.shape.beads, 0)

    expect(riding.length).toBeGreaterThan(0)
    expect(riding.length).toBeLessThanOrEqual(most)
    for (const [x, y, near, size, , strength] of riding) {
      expect(Number.isFinite(x) && Number.isFinite(y)).toBe(true)
      expect(Math.abs(near)).toBeLessThanOrEqual(1)
      expect(size).toBeGreaterThan(0)
      expect(strength).toBeGreaterThanOrEqual(0)
      expect(strength).toBeLessThanOrEqual(1)
    }
  })

  it("moves each bead on toward now at its trail's steady pace, a new one coming in far behind", () => {
    const form = shape("code")
    const span = view.width * view.perPx
    const before = riders(form, 0, span, 10)
    const after = riders(form, 0, span, 10.5)
    const step = (span * form.spin * 0.5) / (form.beads * BEAD_PERIOD)

    expect(after).toHaveLength(before.length)
    // Every bead not just come in moves on by the same step; the one come in
    // stands far behind the head, faint.
    const moved = after.filter(({t}) => before.some(was => Math.abs(t - was.t - step) < 1e-6))
    expect(moved.length).toBeGreaterThanOrEqual(before.length - 1)
    for (const {t, fade} of [...before, ...after]) {
      expect(t).toBeLessThanOrEqual(0)
      expect(t).toBeGreaterThanOrEqual(-span)
      expect(fade).toBeGreaterThanOrEqual(0)
      expect(fade).toBeLessThanOrEqual(1)
    }
  })

  it("rides nothing before a trail begins, and fades into the head", () => {
    const single = lay([event("one", 600, "workspace")], ANCHOR)
    const span = view.width * view.perPx
    for (let clock = 0; clock < 48; clock += 1.5) {
      const begun = riders(single.trails[0].shape, 0, span, clock).filter(({t}) => t >= -600)
      expect(rows(beads(single, view, 0, clock))).toHaveLength(begun.length)
    }
    // Nearly at now, a bead has all but settled into the head.
    expect(along(single.trails[0], -0.001, view, 0)!.out).toBeLessThan(0.001)
  })
})

describe("pointing at a mark", () => {
  it("finds the mark under the pointer, and none far from every mark", () => {
    const layout = lay(history(2_000), ANCHOR)
    const target = layout.placed.findIndex(point => point.t > view.left + 600 && point.event.trail === "code")
    const at = markAt(layout.placed[target], view, 0.4)

    const found = nearest(layout.placed, view, 0.4, at.x, at.y, 24)
    const there = markAt(layout.placed[found!], view, 0.4)

    expect(Math.hypot(there.x - at.x, there.y - at.y)).toBe(0)
    expect(nearest(layout.placed, view, 0.4, -5_000, -5_000, 24)).toBeUndefined()
  })

  it("puts the line's own points on the middle of the picture", () => {
    const layout = lay([event("poll", 1_800, "line", "poll")], ANCHOR)

    expect(markAt(layout.placed[0], view, 1.3)).toEqual({x: 500, y: 300, near: 0})
  })
})
