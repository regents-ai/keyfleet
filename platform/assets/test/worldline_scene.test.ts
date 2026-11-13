import {describe, expect, it} from "vitest"

import {
  BREAK,
  DAY,
  DISTANCE,
  FORM,
  GROW,
  HEADS,
  HOME,
  OPENING,
  PIXEL,
  PLANETS,
  PLANET_SIZE,
  SEGMENTS,
  SUN_SIZE,
  clear,
  heads,
  helixAt,
  lens,
  magnify,
  markAt,
  nearest,
  orbitAngle,
  paths,
  percent,
  place,
  point,
  project,
  streamedAt,
  tips,
  type Box,
  type Camera,
  type Frame,
  type Lens,
  type Mark,
  type Orbit,
  type Vec3,
  type WorldEvent,
} from "../js/worldline/scene"

const ANCHOR = Date.UTC(2026, 10, 12, 9, 30)
const NOW = 40

// The picture as it opens: following now, the sun 0.4 of the span right of
// the middle, not yet flown, its loop beginning well before every event here.
const opening = (camera: Camera = HOME, span = OPENING, anchor = ANCHOR): Frame => ({
  width: 1280,
  height: 560,
  mid: NOW - 0.4 * span,
  span,
  now: NOW,
  anchor,
  camera,
  flown: 0,
  streamed: 0,
  loop: NOW - 30 * DAY,
  emerging: 0,
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
const formula = (planet: number, t: number, frame: Frame, at: Lens): Vec3 => {
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
      const bead = markAt(mark, frame, at)
      const expected = project(formula(planet, mark.t, frame, at), frame, at)
      expect(bead.x).toBeCloseTo(expected.x, 6)
      expect(bead.y).toBeCloseTo(expected.y, 6)
      const onHelix = project(helixAt(PLANETS[planet], mark.t - frame.mid, frame, at), frame, at)
      expect(bead.x).toBeCloseTo(onHelix.x, 6)
      expect(bead.y).toBeCloseTo(onHelix.y, 6)
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

  it("opens close in, on long waves: about one of Workspace's turns across the picture", () => {
    const orbit = drawn.orbits[0]
    const shown = vertices(0, orbit, frame, at)
      .filter(({p}) => {
        const seen = project(p, frame, at)
        return seen.x >= 0 && seen.x <= frame.width && clear(seen.depth, at) > 0.2
      })
      .map(({u}) => u)
    const turns = (Math.max(...shown) - Math.min(...shown)) / PLANETS[0].period
    expect(turns).toBeGreaterThanOrEqual(0.5)
    expect(turns).toBeLessThanOrEqual(2)
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

describe("the flight", () => {
  const events = [
    event("fresh", NOW - 600, "room:general", "message", 3),
    event("w", -3 * 3600, "workspace", "task"),
    event("l", -10 * 3600, "line", "proposal_opened"),
    event("c", -2.5 * DAY, "code", "push"),
    event("n", -5 * DAY, "notebooks", "backup"),
  ]
  const marks = place(events, ANCHOR)
  const oldest = marks.find(mark => mark.event.id === "n")!
  // The loop begins a break before the oldest event.
  const loop = oldest.t - BREAK
  const length = NOW - loop
  // Flown `streamed` seconds round the loop, the orbits as far on and some.
  const flying = (streamed: number, emerging = 1): Frame => ({
    ...opening(),
    flown: 9 * 3600 + streamed,
    streamed,
    loop,
    emerging,
  })

  it("keeps each bead on its planet's helix wherever the flight has carried it", () => {
    for (const streamed of [0, 1234, 3 * 3600, BREAK + 600, 2 * DAY, length - 60]) {
      const frame = flying(streamed)
      const at = lens(frame)
      for (const mark of marks.filter(each => each.lane >= 1 && each.lane <= 3)) {
        const bead = markAt(mark, frame, at)
        const onHelix = project(helixAt(PLANETS[mark.lane - 1], bead.t - frame.mid, frame, at), frame, at)
        expect(bead.x).toBeCloseTo(onHelix.x, 6)
        expect(bead.y).toBeCloseTo(onHelix.y, 6)
      }
    }
  })

  it("streams every event back with its path, so none slides along it", () => {
    const step = 1800
    const before = flying(3 * 3600)
    const after = flying(3 * 3600 + step)
    const at = lens(before)
    // Each event is drawn as much earlier as the flight went on...
    for (const mark of marks) expect(streamedAt(mark.t, after).t).toBeCloseTo(streamedAt(mark.t, before).t - step, 9)
    // ...and each helix moved back by as much, without turning.
    PLANETS.forEach(planet => {
      for (const rel of [-DAY, -4321, 0, NOW - before.mid]) {
        const was = helixAt(planet, rel, before, at)
        const is = helixAt(planet, rel - step, after, at)
        expect(is[0]).toBeCloseTo(was[0] - step / at.unit, 9)
        expect(is[1]).toBeCloseTo(was[1], 6)
        expect(is[2]).toBeCloseTo(was[2], 6)
      }
    })
  })

  it("comes round the loop with nothing popping", () => {
    // The oldest event shrinks away at the loop's end and its copy grows in
    // out of the sun.
    const crossing = oldest.t - loop
    expect(streamedAt(oldest.t, flying(crossing - 1)).full).toBeLessThan(1e-3)
    const copy = streamedAt(oldest.t, flying(crossing + 1))
    expect(copy.t).toBeCloseTo(NOW - 1, 6)
    expect(copy.full).toBeLessThan(1e-3)
    // A whole loop on, every event stands as it began, the newest too.
    for (const mark of marks) {
      const round = streamedAt(mark.t, flying(length))
      const begun = streamedAt(mark.t, flying(0))
      expect(round.t).toBeCloseTo(begun.t, 6)
      expect(round.full).toBeCloseTo(begun.full, 9)
    }
  })

  it("stands every event full at its own time while nothing has streamed", () => {
    for (const mark of marks) expect(streamedAt(mark.t, flying(0, 0))).toEqual({t: mark.t, full: 1})
  })

  it("finds each mark where the flight has carried it, passing over one still growing in", () => {
    const frame = flying(3 * 3600)
    const at = lens(frame)
    marks.forEach((mark, index) => {
      const spot = markAt(mark, frame, at)
      if (spot.x < 0 || spot.x > frame.width || clear(spot.depth, at) < 0.2) return
      expect(nearest(marks, frame, at, spot.x, spot.y, 24)?.index).toBe(index)
    })
    const crossing = oldest.t - loop
    const index = marks.indexOf(oldest)
    const emerging = flying(crossing + 60)
    const grown = flying(crossing + GROW)
    for (const [frame, found] of [
      [emerging, false],
      [grown, true],
    ] as const) {
      const spot = markAt(oldest, frame, lens(frame))
      expect(nearest(marks, frame, lens(frame), spot.x, spot.y, 4)?.index === index).toBe(found)
    }
  })

  it("puts each planet at now where its helix ends, however far it has flown", () => {
    const frame = flying(2 * DAY)
    const at = lens(frame)
    const packed = heads(frame, at)
    const {orbits} = paths(frame, at)
    for (let i = 0; i < HEADS; i++) {
      const [, , radius, angle, , , , , form, , lane] = packed.slice(i * 12, i * 12 + 12)
      if (form === FORM.sun) continue
      const head = point(frame.now, radius, angle, frame, at)
      const end = helixAt(PLANETS[lane - 1], orbits[lane - 1].to, frame, at)
      expect(head[1]).toBeCloseTo(end[1], 5)
      expect(head[2]).toBeCloseTo(end[2], 5)
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
    expect(sun.x).toBeCloseTo(0.9 * frame.width, 2)
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
    // Two rooms' posts at once, one behind the line and one before it.
    const behind: Mark = {...base, lane: 4, radius: 0.3, angle: -Math.PI / 2}
    const before: Mark = {...base, lane: 4, radius: 0.3, angle: Math.PI / 2}
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

describe("the heads' names", () => {
  // Each name's size as the page measures it.
  const SIZES = {
    workspace: {width: 73, height: 20},
    code: {width: 41, height: 20},
    notebooks: {width: 72, height: 20},
    now: {width: 37, height: 20},
  }
  const CAMERAS: Camera[] = [HOME, {yaw: 0, pitch: 0}, {yaw: 1.2, pitch: 0.48}, {yaw: -1.48, pitch: 0.24}, {yaw: 0.6, pitch: -1.1}]
  // The picture wide, and as narrow as a phone shows it.
  const sized = (camera: Camera, width: number, height: number): Frame => ({...opening(camera), width, height})
  // Each, too, moved on until the sun stands near its left edge.
  const FRAMES = CAMERAS.flatMap(camera =>
    [sized(camera, 1280, 512), sized(camera, 354, 288)].flatMap(frame => [frame, {...frame, mid: NOW + 0.45 * frame.span}]),
  )
  const nameOf = (lane: number) => (lane === 0 ? "now" : PLANETS[lane - 1].name)
  // How far a point stands from a box, 0 inside it.
  const away = (box: Box, x: number, y: number) =>
    Math.hypot(x - Math.min(Math.max(x, box.left), box.left + box.width), y - Math.min(Math.max(y, box.top), box.top + box.height))
  const overlap = (a: Box, b: Box) =>
    a.left < b.left + b.width && b.left < a.left + a.width && a.top < b.top + b.height && b.top < a.top + a.height

  it("stands each head where the picture draws it, at any turn and on its way out", () => {
    for (const frame of FRAMES) {
      const at = lens(frame)
      for (const orbiting of [1, 0.5]) {
        const placed = tips(frame, at, orbiting, SIZES)
        const packed = heads(frame, at)
        for (let i = 0; i < HEADS; i++) {
          const [, , radius, angle, , , , , , , lane] = packed.slice(i * 12, i * 12 + 12)
          // The shader draws the planets `orbiting` of the way out.
          const drawn = project(point(frame.now, radius * (lane > 0 ? orbiting : 1), angle, frame, at), frame, at)
          const tip = placed.find(each => each.name === nameOf(lane))!
          // To within the single precision the heads reach the GPU in.
          expect(tip.x).toBeCloseTo(drawn.x, 3)
          expect(tip.y).toBeCloseTo(drawn.y, 3)
          expect(tip.depth).toBeCloseTo(drawn.depth, 3)
        }
      }
    }
  })

  // Every name that stands: beside its head, inside the picture, and off
  // every other head, link and name. Answers how many heads show, and how
  // many of them are named.
  const check = (frame: Frame) => {
    const shown = tips(frame, lens(frame), 1, SIZES).filter(tip => tip.shown)
    const named = shown.filter(tip => tip.label !== null)
    for (const tip of named) {
      const box = tip.label!
      expect(box).toMatchObject(SIZES[tip.name])
      expect(box.left).toBeGreaterThanOrEqual(8)
      expect(box.top).toBeGreaterThanOrEqual(8)
      expect(box.left + box.width).toBeLessThanOrEqual(frame.width - 8)
      expect(box.top + box.height).toBeLessThanOrEqual(frame.height - 8)
      // Beside its own head: clear of it, and within a few pixels of it.
      const disc = ((tip.name === "now" ? SUN_SIZE : PLANET_SIZE) / 2) * magnify(tip.depth)
      expect(away(box, tip.x, tip.y)).toBeGreaterThan(disc)
      expect(away(box, tip.x, tip.y)).toBeLessThan(32)
      for (const other of shown) {
        if (other === tip) continue
        // Off the other heads as drawn, and off the ring each planet's link takes.
        const reach = other.name === "now" ? (SUN_SIZE / 2) * magnify(other.depth) : 16
        expect(away(box, other.x, other.y)).toBeGreaterThanOrEqual(reach)
      }
      for (const other of named) if (other !== tip) expect(overlap(box, other.label!)).toBe(false)
    }
    return {heads: shown.length, names: named.length}
  }

  it("keeps each name beside its head, inside the picture, and off every other head, link and name, at any turn", () => {
    const counts = FRAMES.map(check)
    // And almost every head that shows has its name.
    const sum = (key: "heads" | "names") => counts.reduce((total, count) => total + count[key], 0)
    expect(sum("names") / sum("heads")).toBeGreaterThan(0.85)
  })

  it("keeps the names inside a small picture, however near its edges the heads stand", () => {
    for (let yaw = -1.4; yaw <= 1.4; yaw += 0.35) {
      for (let pitch = -1.1; pitch <= 1.1; pitch += 0.55) {
        for (const along of [0.3, 0.4, 0.45, 0.5]) {
          const frame = sized({yaw, pitch}, 240, 160)
          check({...frame, mid: NOW + along * frame.span})
        }
      }
    }
  })

  it("keeps the names off what stands over the picture", () => {
    const frame = sized(HOME, 1280, 512)
    const at = lens(frame)
    const free = tips(frame, at, 1, SIZES)
    // A box over where each name would stand.
    const blocked = free.map(tip => tip.label!)
    const moved = tips(frame, at, 1, SIZES, blocked)
    for (const tip of moved) {
      if (tip.label === null) continue
      for (const box of blocked) expect(overlap(tip.label, box)).toBe(false)
    }
    expect(moved.filter(tip => tip.label !== null).length).toBeGreaterThan(0)
  })

  it("gives up the later names first when there is not room for all", () => {
    const frame = sized(HOME, 1280, 512)
    const at = lens(frame)
    const wide = {width: 260, height: 60}
    const placed = tips(frame, at, 1, {workspace: wide, code: wide, notebooks: wide, now: wide})
    expect(placed.every(tip => tip.shown)).toBe(true)
    expect(placed.find(tip => tip.name === "workspace")!.label).not.toBeNull()
    expect(placed.filter(tip => tip.label === null).length).toBeGreaterThan(0)
  })

  it("lets the heads and their names go once they are out of the picture, in the past", () => {
    const frame = {...sized(HOME, 1280, 512), mid: NOW - 10 * DAY}
    for (const tip of tips(frame, lens(frame), 1, SIZES)) {
      expect(tip.shown).toBe(false)
      expect(tip.label).toBeNull()
    }
  })
})
