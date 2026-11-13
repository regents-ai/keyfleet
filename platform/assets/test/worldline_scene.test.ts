import {describe, expect, it} from "vitest"

import {
  DAY,
  DISTANCE,
  FORM,
  HOME,
  OPENING,
  PIXEL,
  PLANETS,
  SEGMENTS,
  clear,
  heads,
  helixAt,
  lens,
  markAt,
  nearest,
  orbitAngle,
  paths,
  percent,
  place,
  point,
  project,
  type Camera,
  type Frame,
  type Lens,
  type Mark,
  type Orbit,
  type WorldEvent,
} from "../js/worldline/scene"

const ANCHOR = Date.UTC(2026, 10, 12, 9, 30)
const NOW = 40

// The picture as it opens: following now, the sun 0.35 of the span right of the middle.
const opening = (camera: Camera = HOME, span = OPENING, anchor = ANCHOR): Frame => ({
  width: 1280,
  height: 560,
  mid: NOW - 0.35 * span,
  span,
  now: NOW,
  anchor,
  camera,
})

const event = (id: string, seconds: number, trail: string, kind: string, place: number | null = null): WorldEvent => ({
  id,
  at: ANCHOR + seconds * 1000,
  trail,
  kind,
  place,
  who: null,
  what: kind,
  title: id,
  path: `/x/${id}`,
  live: true,
})

// What the paths shader draws for a helix, instance by instance: vertex v of
// instance i stands `min(from + (i·SEGMENTS + v/2)·step, to)` seconds from the
// middle (pathsWgsl's `u`), placed on the helix by `helixAt`.
const instances = (orbit: Orbit) =>
  Array.from({length: orbit.pieces}, (_, piece) =>
    Array.from({length: (SEGMENTS + 1) * 2}, (_, vertex) =>
      Math.min(orbit.from + (piece * SEGMENTS + Math.floor(vertex / 2)) * orbit.step, orbit.to),
    ),
  )

// The helix as one polyline: every instance's samples, each once, in order.
const vertices = (planet: number, orbit: Orbit, frame: Frame, at: Lens) =>
  instances(orbit)
    .flatMap((piece, i) => piece.filter((_, vertex) => vertex % 2 === 0 && (i === 0 || vertex > 0)))
    .map(u => ({u, p: helixAt(PLANETS[planet], u, frame, at)}))

// Planet p at absolute time T, straight from B(t) = (v·t, R·cos(2πt/P + φ), R·sin(2πt/P + φ)).
const formula = (planet: number, t: number, frame: Frame, at: Lens) => {
  const {radius, period, offset} = PLANETS[planet]
  const angle = (2 * Math.PI * (frame.anchor / 1000 + t)) / period + offset
  return [(t - frame.mid) / at.unit, radius * Math.cos(angle), radius * Math.sin(angle)]
}

describe("the planets' helices", () => {
  const frame = opening()
  const at = lens(frame)
  const drawn = paths(frame, at)

  it("draws exactly one continuous helix per planet", () => {
    expect(drawn.orbits).toHaveLength(PLANETS.length)
    drawn.orbits.forEach((orbit, planet) => {
      // Each instance begins where the one before it ends.
      const pieces = instances(orbit)
      for (let i = 1; i < pieces.length; i++) expect(pieces[i][0]).toBe(pieces[i - 1][pieces[i - 1].length - 1])
      const points = vertices(planet, orbit, frame, at)
      expect(points[0].u).toBe(orbit.from)
      // One polyline: each vertex follows the last in time, a short step on.
      for (let i = 1; i < points.length; i++) {
        expect(points[i].u).toBeGreaterThanOrEqual(points[i - 1].u)
        const [a, b] = [points[i - 1].p, points[i].p]
        const reach = orbit.step / at.unit + (2 * Math.PI * PLANETS[planet].radius * orbit.step) / PLANETS[planet].period
        expect(Math.hypot(b[0] - a[0], b[1] - a[1], b[2] - a[2])).toBeLessThanOrEqual(reach + 1e-9)
      }
    })
  })

  it("keeps every vertex on its planet's circle and ends at the planet in the plane of the present", () => {
    const present = (frame.now - frame.mid) / at.unit
    drawn.orbits.forEach((orbit, planet) => {
      const points = vertices(planet, orbit, frame, at)
      const {radius} = PLANETS[planet]
      for (const {u, p} of points) {
        expect(Math.hypot(p[1], p[2])).toBeCloseTo(radius, 9)
        expect(p[0]).toBeLessThanOrEqual(present + 1e-9)
        const expected = formula(planet, frame.mid + u, frame, at)
        expect(p[0]).toBeCloseTo(expected[0], 9)
        expect(p[1]).toBeCloseTo(expected[1], 6)
        expect(p[2]).toBeCloseTo(expected[2], 6)
      }
      expect(points[points.length - 1].p[0]).toBeCloseTo(present, 9)
    })
  })

  it("puts each planet at now exactly where its helix ends", () => {
    const packed = heads(frame, at)
    const ends = drawn.orbits.map((orbit, planet) => {
      const points = vertices(planet, orbit, frame, at)
      return points[points.length - 1].p
    })
    for (let i = 0; i < 4; i++) {
      const [hi, lo, radius, angle, , , , , form, , lane] = packed.slice(i * 12, i * 12 + 12)
      expect(hi + lo).toBeCloseTo(frame.now, 6)
      if (form === FORM.sun) {
        expect(radius).toBe(0)
        continue
      }
      expect(form).toBe(FORM.planet)
      const head = point(frame.now, radius, angle, frame, at)
      const end = ends[lane - 1]
      expect(head[1]).toBeCloseTo(end[1], 5)
      expect(head[2]).toBeCloseTo(end[2], 5)
    }
  })

  it("puts each event's bead on its planet's helix at the event's time", () => {
    const events = [
      event("w", -3 * 3600, "workspace", "task"),
      event("c", -2.5 * DAY, "code", "push"),
      event("n", -5 * DAY, "notebooks", "backup"),
    ]
    for (const mark of place(events, ANCHOR)) {
      const planet = mark.lane - 1
      const bead = point(mark.t, mark.radius, mark.angle, frame, at)
      const expected = formula(planet, mark.t, frame, at)
      bead.forEach((value, axis) => expect(value).toBeCloseTo(expected[axis], 6))
      const onHelix = helixAt(PLANETS[planet], mark.t - frame.mid, frame, at)
      onHelix.forEach((value, axis) => expect(value).toBeCloseTo(bead[axis], 6))
    }
  })

  it("stands the same at the same moment whenever the page was read, and whatever events there are", () => {
    // The same picture, its anchor seven hours later.
    const shift = 7 * 3600
    const later = {...frame, anchor: ANCHOR + shift * 1000, mid: frame.mid - shift, now: frame.now - shift}
    const seen = lens(later)
    PLANETS.forEach((planet, i) => {
      for (const rel of [-4 * DAY, -1234, 0, frame.now - frame.mid]) {
        const first = helixAt(planet, rel, frame, at)
        helixAt(planet, rel, later, seen).forEach((value, axis) => expect(value).toBeCloseTo(first[axis], 6))
      }
      const angle = orbitAngle(planet, 1234, ANCHOR)
      const again = orbitAngle(planet, 1234 - shift, later.anchor)
      expect(Math.cos(again)).toBeCloseTo(Math.cos(angle), 6)
      expect(Math.sin(again)).toBeCloseTo(Math.sin(angle), 6)
      expect(paths(later, seen).orbits[i].pieces).toBe(drawn.orbits[i].pieces)
    })
    // Paths take the frame alone: reading another page changes none of them.
    expect(paths(frame, at)).toEqual(drawn)
  })

  it("opens on clean coils: three to eight of Workspace's turns across the picture", () => {
    const orbit = drawn.orbits[0]
    const shown = vertices(0, orbit, frame, at)
      .filter(({p}) => {
        const seen = project(p, frame, at)
        return seen.x >= 0 && seen.x <= frame.width && clear(seen.depth, at) > 0.2
      })
      .map(({u}) => u)
    const turns = (Math.max(...shown) - Math.min(...shown)) / PLANETS[0].period
    expect(turns).toBeGreaterThanOrEqual(3)
    expect(turns).toBeLessThanOrEqual(8)
    expect(percent(OPENING)).toBe("100%")
  })

  it("draws nothing past now, and never ends a path in view on the left", () => {
    for (const camera of [HOME, {yaw: 0, pitch: 0}, {yaw: -1.2, pitch: 0.6}, {yaw: 1.48, pitch: -0.4}]) {
      const shown = opening(camera)
      const seen = lens(shown)
      const {line, orbits} = paths(shown, seen)
      expect(line.to).toBeCloseTo(shown.now - shown.mid, 9)
      for (const orbit of orbits) expect(orbit.to).toBeLessThanOrEqual(shown.now - shown.mid)
      const start = project(point(shown.mid + line.from, 0, 0, shown, seen), shown, seen)
      const outside = start.x < 0 || start.x > shown.width || start.y < 0 || start.y > shown.height
      expect(outside || clear(start.depth, seen) < 0.05).toBe(true)
    }
  })
})

describe("the camera", () => {
  it("looks at the line's middle from its distance, at any turn", () => {
    for (const camera of [HOME, {yaw: 0, pitch: 0}, {yaw: -1.4, pitch: 1.1}, {yaw: 1.48, pitch: -1.2}]) {
      const frame = opening(camera)
      const at = lens(frame)
      const middle = project(point(frame.mid, 0, 0, frame, at), frame, at)
      // To within the GPU's single-precision matrix.
      expect(middle.x).toBeCloseTo(frame.width / 2, 3)
      expect(middle.y).toBeCloseTo(frame.height / 2, 3)
      expect(middle.depth).toBeCloseTo(DISTANCE, 5)
    }
  })

  it("seen side on, spans the picture's width with the span", () => {
    const frame = opening({yaw: 0, pitch: 0})
    const at = lens(frame)
    const left = project(point(frame.mid - frame.span / 2, 0, 0, frame, at), frame, at)
    const right = project(point(frame.mid + frame.span / 2, 0, 0, frame, at), frame, at)
    const sun = project(point(frame.now, 0, 0, frame, at), frame, at)
    expect(left.x).toBeCloseTo(0, 2)
    expect(right.x).toBeCloseTo(frame.width, 2)
    expect(sun.x).toBeCloseTo(0.85 * frame.width, 2)
  })
})

describe("pointing at marks", () => {
  const events = [
    event("a", -6 * 3600, "workspace", "task"),
    event("b", -30 * 3600, "code", "push"),
    event("c", -3 * DAY, "notebooks", "backup"),
    event("d", -10 * 3600, "line", "proposal_opened"),
    event("e", -2 * 3600, "room:general", "message", 7),
  ]
  const marks = place(events, ANCHOR)

  it("finds the mark under the pointer at any turn of the camera", () => {
    for (const camera of [HOME, {yaw: 0, pitch: 0}, {yaw: -0.9, pitch: 0.7}, {yaw: 1.3, pitch: -0.5}]) {
      const frame = opening(camera)
      const at = lens(frame)
      marks.forEach((mark, index) => {
        const spot = markAt(mark, frame, at)
        if (spot.x < 0 || spot.x > frame.width || clear(spot.depth, at) < 0.2) return
        expect(nearest(marks, frame, at, spot.x, spot.y, 24)?.index).toBe(index)
      })
    }
  })

  it("on a tie takes the mark nearer the camera", () => {
    const frame = opening({yaw: 0, pitch: 0})
    const at = lens(frame)
    const base = place([event("x", frame.mid, "line", "vote")], ANCHOR)[0]
    const behind: Mark = {...base, lane: 1, radius: 0.3, angle: -Math.PI / 2}
    const before: Mark = {...base, lane: 1, radius: 0.3, angle: Math.PI / 2}
    const centre = project(point(frame.mid, 0, 0, frame, at), frame, at)
    expect(nearest([behind, before], frame, at, centre.x, centre.y, 24)?.index).toBe(1)
    expect(nearest([before, behind], frame, at, centre.x, centre.y, 24)?.index).toBe(0)
  })
})

describe("the rooms", () => {
  // How much of a room's line its posts cover: the distinct pixels they fill.
  const coverage = (perHour: number, frame: Frame, at: Lens) => {
    const posts = Array.from({length: Math.round(perHour * 6)}, (_, i) =>
      event(`p${i}`, -6 * 3600 + (i * 3600) / perHour, "room:general", "message", i + 1),
    )
    const cells = new Set(
      place(posts, ANCHOR).map(mark => {
        const spot = markAt(mark, frame, at)
        return `${Math.round(spot.x / PIXEL)}:${Math.round(spot.y / PIXEL)}`
      }),
    )
    return cells.size
  }

  it("are pixels on their own lines, never paths", () => {
    const [mark] = place([event("m", -60, "room:people", "message", 3)], ANCHOR)
    expect(mark.form).toBe(FORM.pixel)
    expect(mark.lane).toBe(4)
    const frame = opening()
    expect(paths(frame, lens(frame)).orbits).toHaveLength(PLANETS.length)
  })

  it("fill more of their line the busier they are", () => {
    const frame = opening()
    const at = lens(frame)
    const rates = [1, 4, 16, 64, 256]
    const filled = rates.map(rate => coverage(rate, frame, at))
    for (let i = 1; i < filled.length; i++) expect(filled[i]).toBeGreaterThanOrEqual(filled[i - 1])
    expect(filled[filled.length - 1]).toBeGreaterThan(filled[0])
  })

  it("show one pixel apart for each post, zoomed in", () => {
    const span = 120
    const frame = {...opening(HOME, span), mid: NOW - 60}
    const at = lens(frame)
    const posts = Array.from({length: 12}, (_, i) => event(`q${i}`, NOW - 60 + i * 5 - 30, "room:general", "message", i + 1))
    const spots = place(posts, ANCHOR).map(mark => markAt(mark, frame, at))
    for (let i = 0; i < spots.length; i++) {
      for (let j = i + 1; j < spots.length; j++) {
        expect(Math.hypot(spots[i].x - spots[j].x, spots[i].y - spots[j].y)).toBeGreaterThanOrEqual(PIXEL)
      }
    }
  })
})
