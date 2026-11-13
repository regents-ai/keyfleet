/**
 * Where everything on a fleet's Worldline stands: the line runs through time
 * from left to right, and each trail turns around it as a helix seen a little
 * from above, each at its own steady pace through time, and every trail
 * settles into the head at now. After each of its events a trail curls up
 * into a loop, its event a bead at the loop's tip, then runs on smoothly to
 * the next. The sooner its next event, the tighter an event's curl, so a
 * burst of events leaves a run of tight curls, which from far off show as
 * one curl at the burst's end. Nothing here is random: the same events
 * always lay out the same way, and a room's trail takes its shape from the
 * room's own name.
 *
 * Times are seconds from the anchor, the moment the page was first read. How
 * far a trail has turned depends on the time alone, and a curl only on what
 * follows it, so older events read later never move what is already drawn.
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
  /** Where around the line it stood as 1970 began, in radians; laid out, where it stood at the anchor. */
  readonly phase: number
  /** How far its turns lean along the line, in radians; the lean draws its wide loops. */
  readonly tilt: number
  /** How fast it turns as the picture orbits, against the main trails' 1. */
  readonly spin: number
  /** How long it takes to turn once around the line, in seconds. */
  readonly turn: number
  /** The widest an event's curl grows, 0..1 of the reach. */
  readonly curl: number
  /** How many beads ride it at once. */
  readonly beads: number
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
  /** Seconds on to its trail's next event, which sizes its curl; for a trail's newest, `QUIET`. */
  readonly gap: number
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

/** What the picture shows: its size in CSS pixels, the time across it, and now. */
export type View = {
  /** Seconds from the anchor at the left edge. */
  readonly left: number
  /** Seconds across one CSS pixel. */
  readonly perPx: number
  readonly width: number
  readonly height: number
  /** Seconds from the anchor to now, where the head stands. */
  readonly now: number
}

/** How far the furthest trail reaches from the line, against the picture's height. */
export const REACH = 0.44
/** How far the picture looks down on the line, in radians. */
export const ELEVATION = 0.38
/**
 * An event's curl turns once around while the line runs on `CURL_TURN`
 * times its width, or less on to now, and so stays clear of the next event:
 * it is at most `CURL_SHARE` of the way there.
 */
export const CURL_TURN = 2.2
export const CURL_SHARE = 1 / CURL_TURN
/** How far off a trail's newest event takes its next one to be, in seconds: a year. */
export const QUIET = 365 * 24 * 3600
/** The share of the picture's width over which every trail settles into the head. */
export const SETTLE = 0.15

const DAY = 24 * 3600

const MAIN: Record<string, Shape> = {
  notebooks: {radius: 0.44, phase: 0.6, tilt: 0.9, spin: 1.15, turn: 2.5 * DAY, curl: 0.1, beads: 3, width: 1.75, strength: 0.8, tone: TONE.notebooks},
  workspace: {radius: 0.64, phase: 2.5, tilt: 0.78, spin: 1, turn: 3.5 * DAY, curl: 0.1, beads: 3, width: 2.25, strength: 0.85, tone: TONE.workspace},
  code: {radius: 0.84, phase: 4.2, tilt: 0.66, spin: 0.85, turn: 5 * DAY, curl: 0.1, beads: 3, width: 1.5, strength: 0.95, tone: TONE.code},
}

// The line reaches nowhere from itself, so however it turns it stays put.
const LINE: Shape = {radius: 0, phase: 0, tilt: 0, spin: 0, turn: DAY, curl: 0, beads: 0, width: 2.5, strength: 1, tone: TONE.line}

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
  // Rooms keep close to the line, where their talk curls small.
  return {
    radius: 0.14 + 0.22 * part(0),
    phase: 2 * Math.PI * part(8),
    tilt: 0.3 + 0.5 * part(16),
    spin: 0.7 + 0.6 * part(24),
    turn: (1.5 + 2 * part(4)) * DAY,
    curl: 0.06,
    beads: 1,
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
      return [3.5, 1, trail.tone]
  }
}

// A trail laid out from `anchor` (ms) turns from where it stood then, so it
// stands as far around at any moment whenever the page was read.
const anchored = (form: Shape, anchor: number): Shape => ({
  ...form,
  phase: form.phase + (2 * Math.PI * ((anchor / 1000) % form.turn)) / form.turn,
})

const byTime = (a: WorldEvent, b: WorldEvent) => a.at - b.at || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)

/**
 * Lays out `events` around the line, in seconds from `anchor` (ms), the
 * newest `MAX_EVENTS` of them.
 */
export function lay(events: readonly WorldEvent[], anchor: number): Layout {
  const sorted = [...events].sort(byTime).slice(-MAX_EVENTS)
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
    const form = anchored(shape(name), anchor)
    const knots = group.map((event, i) => {
      const [size, strength, tone] = mark(event, form)
      const next = group[i + 1]
      const placed: Placed = {
        event,
        t: (event.at - anchor) / 1000,
        gap: next === undefined ? QUIET : (next.at - event.at) / 1000,
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
 * How wide an event's curl is drawn, in CSS pixels: its trail's widest, or
 * less when its next event stands close on the picture.
 */
export function curlAt(gap: number, form: Shape, view: View): number {
  return Math.min(form.curl * REACH * view.height, (CURL_SHARE * gap) / view.perPx)
}

const smoothstep = (k: number) => k * k * (3 - 2 * k)

/**
 * How far out a trail runs at time `t`, 0..1: all the way, until it settles
 * into the head over the last `SETTLE` of the picture before now.
 */
export function settled(t: number, view: View): number {
  return smoothstep(Math.min(1, Math.max(0, (view.now - t) / view.perPx / (SETTLE * view.width))))
}

/**
 * How far the line runs on, in CSS pixels, while an event's curl `coil`
 * pixels wide turns once around: `CURL_TURN` times its width, or less when
 * now comes sooner.
 */
export function across(point: Placed, coil: number, view: View): number {
  return Math.min(CURL_TURN * coil, Math.max(0, Math.min(point.gap, view.now - point.t)) / view.perPx)
}

/** How far a curl that turns once over `across` CSS pixels has turned `after` pixels on, in radians. */
export function swirl(after: number, across: number): number {
  return 2 * Math.PI * Math.min(1, Math.max(0, after / Math.max(across, 1e-3)))
}

/**
 * Where a point of a trail stands in the picture at time `t`, in CSS pixels,
 * and how near the reader it is, -1 behind the line to 1 in front: the trail
 * turned as far as it has by then, and a curl `coil` pixels wide turned psi
 * from its foot, both drawn in as the trail settles into the head. Every
 * curl rises from the trail and faces the reader, its tip up, as the
 * reference picture's do. The shader draws the same sum (`shader.ts`).
 */
export function project(
  t: number,
  psi: number,
  coil: number,
  form: Shape,
  view: View,
  orbit: number,
): {x: number; y: number; near: number} {
  const out = settled(t, view)
  const reach = form.radius * REACH * view.height * out
  const curl = coil * out
  const angle = (2 * Math.PI * t) / form.turn + form.phase + orbit * form.spin
  const sin = Math.sin(angle)
  const cos = Math.cos(angle)
  const up = reach * cos
  const deep = reach * sin * Math.cos(form.tilt)
  return {
    x: (t - view.left) / view.perPx + reach * sin * Math.sin(form.tilt) + curl * Math.sin(psi),
    y: view.height / 2 - (up * Math.cos(ELEVATION) - deep * Math.sin(ELEVATION)) - curl * (1 - Math.cos(psi)),
    near: reach > 0 ? (up * Math.sin(ELEVATION) + deep * Math.cos(ELEVATION)) / reach : 0,
  }
}

/** Where an event's mark stands: at the tip of its curl, half a turn on. */
export function markAt(point: Placed, view: View, orbit: number) {
  const coil = curlAt(point.gap, point.shape, view)
  const tip = point.t + 0.5 * across(point, coil, view) * view.perPx
  return project(tip, Math.PI, coil, point.shape, view, orbit)
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
    // A mark strays from its time by no more than its trail's reach and curl.
    const reach = (point.shape.radius + CURL_TURN * point.shape.curl) * REACH * view.height
    const plain = (point.t - view.left) / view.perPx
    if (Math.abs(plain - x) > within + reach) continue
    const at = markAt(point, view, orbit)
    const distance = (at.x - x) ** 2 + (at.y - y) ** 2
    if (distance <= bestDistance) {
      best = i
      bestDistance = distance
    }
  }
  return best
}

/**
 * Where time `t` stands on a trail, drawn as the shader draws its stretch
 * there, and how far out it runs, 1 to 0 at the head; nothing before the
 * trail's first event.
 */
export function along(trail: Trail, t: number, view: View, orbit: number) {
  const {knots, shape: form} = trail
  if (knots.length === 0 || t < knots[0].t) return undefined
  let low = 0
  let high = knots.length - 1
  while (low < high) {
    const middle = (low + high + 1) >> 1
    if (knots[middle].t <= t) low = middle
    else high = middle - 1
  }
  const knot = knots[low]
  const coil = curlAt(knot.gap, form, view)
  const psi = swirl((t - knot.t) / view.perPx, across(knot, coil, view))
  return {...project(t, psi, coil, form, view, orbit), out: settled(t, view)}
}

/** How long a bead takes to move up to where the next one was, in seconds, on a trail of spin 1. */
export const BEAD_PERIOD = 16

/**
 * When the beads riding a trail of this shape stand at `clock` seconds, and
 * how far each has faded in: its few, evenly spread over `span` seconds
 * behind `now`, drift on toward now and fade in far behind it.
 */
export function riders(form: Shape, now: number, span: number, clock: number): {t: number; fade: number}[] {
  const drift = ((((clock * form.spin) / BEAD_PERIOD + form.phase / (2 * Math.PI)) % 1) + 1) % 1
  return Array.from({length: form.beads}, (_, j) => {
    const back = (j + 1 - drift) / form.beads
    return {t: now - back * span, fade: smoothstep(Math.min(1, (1 - back) / 0.25))}
  })
}

/**
 * The beads riding the trails at `clock` seconds, across the picture's width
 * behind the head, each on its trail where it began and fading into the head
 * at now. Each is its place in CSS pixels, how near the reader it is, its
 * width, its colour and its strength, as `BEAD_FLOATS` floats.
 */
export function beads(layout: Layout, view: View, orbit: number, clock: number): Float32Array<ArrayBuffer> {
  const rows: number[] = []
  const span = view.width * view.perPx
  for (const trail of layout.trails) {
    for (const {t, fade} of riders(trail.shape, view.now, span, clock)) {
      const at = along(trail, t, view, orbit)
      if (at === undefined) continue
      const begun = smoothstep(Math.min(1, (t - trail.knots[0].t) / (0.08 * span)))
      rows.push(at.x, at.y, at.near, 2 * trail.shape.width + 1, trail.shape.tone, fade * begun * at.out, 0, 0)
    }
  }
  return new Float32Array(rows)
}

/** As many events as the picture holds; the list holds every one. */
export const MAX_EVENTS = 12_000
/** As many beads as the picture draws. */
export const MAX_BEADS = 256

/** Floats in one instance of a stretch of trail, of a point, and of a bead. */
export const SEGMENT_FLOATS = 16
export const POINT_FLOATS = 16
export const BEAD_FLOATS = 8

/** How the shader reads a stretch's flag: one that runs on to now, or the line itself. */
const TO_NOW = 1
const THE_LINE = 2
/** How the shader reads a point's form: a square pixel, or the line's head. */
const PIXEL = 1
const HEAD = 2
/** The head's width, in CSS pixels. */
const HEAD_SIZE = 16

/**
 * The layout as the GPU draws it: each trail's stretches from event to event
 * and on to now, then the line over them; every event's mark, in `placed`
 * order, then the head over them.
 */
export function pack(layout: Layout): {segments: Float32Array<ArrayBuffer>; points: Float32Array<ArrayBuffer>} {
  const rows: number[][] = []
  for (const trail of layout.trails) {
    if (trail.shape.radius === 0) continue
    const {radius, phase, tilt, spin, turn, tone, width, strength, curl} = trail.shape
    trail.knots.forEach((knot, i) => {
      const next = trail.knots[i + 1] ?? knot
      rows.push([
        knot.t, next.t, knot.gap, 0,
        radius, phase, tilt, spin,
        tone, width, strength, next === knot ? TO_NOW : 0,
        turn, curl, 0, 0,
      ])
    })
  }
  rows.push([0, 0, 0, 0, 0, 0, 0, 0, LINE.tone, LINE.width, LINE.strength, THE_LINE, 1, 0, 0, 0])

  const marks = layout.placed.map((point, i) => {
    const {radius, phase, tilt, spin, turn, curl} = point.shape
    return [
      point.t, point.gap, turn, curl,
      radius, phase, tilt, spin,
      point.size, point.tone, i, point.strength,
      point.pixel ? PIXEL : 0, 0, 0, 0,
    ]
  })
  marks.push([0, 0, 1, 0, 0, 0, 0, 0, HEAD_SIZE, TONE.line, -1, 1, HEAD, 0, 0, 0])

  return {segments: new Float32Array(rows.flat()), points: new Float32Array(marks.flat())}
}
