/**
 * Where everything on a fleet's Worldline stands: the line runs through time
 * from left to right, and each trail turns around it as a helix seen a little
 * from above. A trail turns by a fixed step at each of its events, so a burst
 * of events curls it into loops where it happened and a quiet spell leaves it
 * a gentle wave. Nothing here is random: the same events always lay out the
 * same way, and a room's trail takes its shape from the room's own name.
 *
 * Times are seconds from the anchor, the moment the page was first read. A
 * trail's turns are counted from the anchor too, outward both ways, so older
 * events read later and newer ones arriving never move what is already drawn.
 */

/** One event, as the page sends it (`KeyfleetWeb.WorldlineLive`). */
export type WorldEvent = {
  readonly id: string
  /** When it happened, in milliseconds since 1970. */
  readonly at: number
  /** "workspace", "code", "notebooks", "room:<slug>", or "line" for proposals and polls. */
  readonly trail: string
  readonly kind: string
  readonly who: string | null
  readonly what: string
  readonly title: string
  readonly path: string
  readonly live: boolean
}

/** The colours a picture is drawn in, by their place in the shader's palette. */
export const TONE = {
  line: 0,
  workspace: 1,
  code: 2,
  notebooks: 3,
  chat: 4,
  opened: 5,
  closed: 6,
  poll: 7,
} as const

/** How a trail turns around the line. */
export type Shape = {
  /** How far out it runs, 0..1 of the reach (`REACH` of the picture's height). */
  readonly radius: number
  /** Where around the line it starts, in radians. */
  readonly phase: number
  /** How far its turns lean along the line, in radians; the lean is what draws loops. */
  readonly tilt: number
  /** How fast it turns as the picture orbits, against the main trails' 1. */
  readonly spin: number
  /** How far it turns at each of its events, in radians. */
  readonly step: number
  /** Its line's width and strength, in CSS pixels and 0..1. */
  readonly width: number
  readonly strength: number
  readonly tone: number
}

/** An event where it stands on its trail. */
export type Placed = {
  readonly event: WorldEvent
  /** Seconds from the anchor. */
  readonly t: number
  /** How far its trail has turned there, in radians. */
  readonly theta: number
  readonly shape: Shape
  /** Its mark's width in CSS pixels, its strength 0..1 and its colour. */
  readonly size: number
  readonly strength: number
  readonly tone: number
  /** A chat post is one square pixel; everything else a round point. */
  readonly pixel: boolean
}

export type Trail = {readonly name: string; readonly shape: Shape; readonly knots: readonly Placed[]}

export type Layout = {
  readonly trails: readonly Trail[]
  /** Every event, oldest first; a point's index here is its index on the GPU. */
  readonly placed: readonly Placed[]
}

/** What the picture shows: its size in CSS pixels, and the time across it. */
export type View = {
  /** Seconds from the anchor at the left edge. */
  readonly left: number
  /** Seconds across one CSS pixel. */
  readonly perPx: number
  readonly width: number
  readonly height: number
}

/** How far the furthest trail reaches from the line, against the picture's height. */
export const REACH = 0.44
/** How far the picture looks down on the line, in radians. */
export const ELEVATION = 0.38

const QUARTER = Math.PI / 2
const SIXTH = Math.PI / 3

const MAIN: Record<string, Shape> = {
  notebooks: {radius: 0.5, phase: 0.6, tilt: 0.95, spin: 1.15, step: QUARTER, width: 1.75, strength: 0.75, tone: TONE.notebooks},
  workspace: {radius: 0.72, phase: 2.5, tilt: 0.8, spin: 1, step: QUARTER, width: 2, strength: 0.8, tone: TONE.workspace},
  code: {radius: 0.94, phase: 4.2, tilt: 0.66, spin: 0.85, step: QUARTER, width: 1.75, strength: 0.8, tone: TONE.code},
}

const LINE: Shape = {radius: 0, phase: 0, tilt: 0, spin: 0, step: 0, width: 2.5, strength: 1, tone: TONE.line}

// FNV-1a, so a room's name always gives its trail the same shape.
const hash = (text: string) => {
  let value = 0x811c9dc5
  for (let i = 0; i < text.length; i++) {
    value ^= text.charCodeAt(i)
    value = Math.imul(value, 0x01000193)
  }
  return value >>> 0
}

/** The shape of the trail named `trail`. */
export function shape(trail: string): Shape {
  if (trail === "line") return LINE
  const main = MAIN[trail]
  if (main) return main
  const bits = hash(trail)
  const part = (shift: number) => ((bits >>> shift) & 0xff) / 255
  // Rooms keep close to the line, where their talk curls into narrow loops.
  return {
    radius: 0.16 + 0.3 * part(0),
    phase: 2 * Math.PI * part(8),
    tilt: 0.3 + 0.5 * part(16),
    spin: 0.7 + 0.6 * part(24),
    step: SIXTH,
    width: 1,
    strength: 0.42,
    tone: TONE.chat,
  }
}

// Each kind's mark: its width in CSS pixels, its strength and its colour.
const mark = (event: WorldEvent, trail: Shape): [number, number, number] => {
  switch (event.kind) {
    case "post":
      return [1.5, 0.95, trail.tone]
    case "room_named":
      return [2.5, 1, trail.tone]
    case "poll":
      return [5, 1, TONE.poll]
    case "proposal_opened":
      return [5.5, 1, TONE.opened]
    case "proposal_closed":
      return [5, 1, TONE.closed]
    default:
      return [3.25, 1, trail.tone]
  }
}

const byTime = (a: WorldEvent, b: WorldEvent) => a.at - b.at || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)

/** Lays out `events` around the line, turning each trail from `anchor` (ms). */
export function lay(events: readonly WorldEvent[], anchor: number): Layout {
  const sorted = [...events].sort(byTime)
  const groups = new Map<string, WorldEvent[]>()
  for (const event of sorted) {
    const group = groups.get(event.trail)
    if (group) group.push(event)
    else groups.set(event.trail, [event])
  }

  const placedById = new Map<string, Placed>()
  const trails: Trail[] = []
  for (const name of [...groups.keys()].sort()) {
    const group = groups.get(name)!
    const form = shape(name)
    // The trail's last turn at or before the anchor is its turn 0.
    const zero = group.filter(event => event.at <= anchor).length - 1
    const knots = group.map((event, i) => {
      const [size, strength, tone] = mark(event, form)
      const placed: Placed = {
        event,
        t: (event.at - anchor) / 1000,
        theta: form.step * (i - zero),
        shape: form,
        size,
        strength,
        tone,
        pixel: event.kind === "post",
      }
      placedById.set(event.id, placed)
      return placed
    })
    trails.push({name, shape: form, knots})
  }

  return {trails, placed: sorted.map(event => placedById.get(event.id)!)}
}

/**
 * Where a point of a trail stands in the picture, in CSS pixels, and how near
 * the reader it is, -1 behind the line to 1 in front. The shader draws the
 * same sum (`shader.ts`).
 */
export function project(
  t: number,
  theta: number,
  form: Shape,
  view: View,
  orbit: number,
): {x: number; y: number; near: number} {
  const reach = form.radius * REACH * view.height
  const angle = theta + form.phase + orbit * form.spin
  const sin = Math.sin(angle)
  const cos = Math.cos(angle)
  const along = reach * sin * Math.sin(form.tilt)
  const up = reach * cos
  const deep = reach * sin * Math.cos(form.tilt)
  return {
    x: (t - view.left) / view.perPx + along,
    y: view.height / 2 - (up * Math.cos(ELEVATION) - deep * Math.sin(ELEVATION)),
    near: reach > 0 ? (up * Math.sin(ELEVATION) + deep * Math.cos(ELEVATION)) / reach : 0,
  }
}

/** The event whose mark is nearest (x, y), within `within` CSS pixels, by its index in `placed`. */
export function nearest(
  placed: readonly Placed[],
  view: View,
  orbit: number,
  x: number,
  y: number,
  within: number,
): number | undefined {
  let best: number | undefined
  let bestDistance = within * within
  for (let i = 0; i < placed.length; i++) {
    const point = placed[i]
    // A mark strays from its time by no more than its trail's reach.
    const reach = point.shape.radius * REACH * view.height
    const plain = (point.t - view.left) / view.perPx
    if (Math.abs(plain - x) > within + reach) continue
    const at = project(point.t, point.theta, point.shape, view, orbit)
    const distance = (at.x - x) ** 2 + (at.y - y) ** 2
    if (distance <= bestDistance) {
      best = i
      bestDistance = distance
    }
  }
  return best
}

/** As many events as the picture holds; the list holds every one. */
export const MAX_EVENTS = 12_000

/** Floats in one instance of a stretch of trail, and of a point. */
export const SEGMENT_FLOATS = 12
export const POINT_FLOATS = 12

/** How the shader reads an instance's last float: a stretch that runs on to now, or the line itself. */
const TO_NOW = 1
const THE_LINE = 2
/** How the shader reads a point's last float: a square pixel, or the line's head. */
const PIXEL = 1
const HEAD = 2

/**
 * The layout as the GPU draws it: the line and its head first, then each
 * trail's stretches from event to event and on to now, then every event's
 * mark, in `placed` order.
 */
export function pack(layout: Layout): {segments: Float32Array<ArrayBuffer>; points: Float32Array<ArrayBuffer>} {
  const rows: number[][] = [[0, 0, 0, 0, 0, 0, 0, 0, LINE.tone, LINE.width, LINE.strength, THE_LINE]]
  for (const trail of layout.trails) {
    if (trail.shape.radius === 0) continue
    const {radius, phase, tilt, spin, tone, width, strength} = trail.shape
    trail.knots.forEach((knot, i) => {
      const next = trail.knots[i + 1] ?? knot
      rows.push([
        knot.t, knot.theta, next.t, next.theta,
        radius, phase, tilt, spin,
        tone, width, strength, next === knot ? TO_NOW : 0,
      ])
    })
  }

  const marks: number[][] = [[0, 0, 0, 0, 0, 0, 20, TONE.line, -1, 1, 1, HEAD]]
  layout.placed.forEach((point, i) => {
    const {radius, phase, tilt, spin} = point.shape
    marks.push([
      point.t, point.theta, radius, phase,
      tilt, spin, point.size, point.tone,
      i, point.strength, 0, point.pixel ? PIXEL : 0,
    ])
  })

  return {segments: new Float32Array(rows.flat()), points: new Float32Array(marks.flat())}
}
