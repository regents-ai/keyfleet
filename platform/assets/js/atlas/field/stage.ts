/**
 * The Atlas as a field: every project is a cluster on one endless canvas, the
 * busiest in the middle, and inside each cluster a patch for each kind of
 * work, where the window's hours wind outward from its first hour in the
 * middle to its newest on the outside (`./layout`). Zooming is continuous
 * and changes what is shown: from far away each cluster glows with its work,
 * brighter and bigger where it worked lately; closer, its hours resolve into
 * blocks of work by kind; closer still, each hour into a point for each thing
 * changed in it; and at last into cards that link to each thing's page. A
 * ring pulses where work happened in the last hour, and stays, still, for a
 * reader who asked for less motion.
 *
 * Nothing the fleet ever did reaches the browser at once. The page answers
 * (`atlas_field_cells`) for each kind of each project over the whole window,
 * for today and the last hour, then for the hours of the projects on screen,
 * and (`atlas_field_things`) for the things of the hours on screen. When the
 * fleet's work is counted again the page says so (`changed`), and what is on
 * screen is read again in place.
 *
 * The wheel and a pinch zoom about the pointer; dragging moves. Pressing a
 * cluster or an hour looks closer at it. With the keyboard, the arrow keys
 * move a ring from cluster to cluster, or hour to hour once a cluster is
 * open, where it starts on the busiest kind's newest work; plus and minus
 * zoom about it, and Enter looks closer, or, among the
 * cards, moves to the first card; Tab steps through the cards in reading
 * order, Escape leaves them. Choosing a thing in the strip brings the field
 * to its card.
 *
 * The glows, blocks and points are drawn on the GPU (`./renderer`), and only
 * redrawn when something moved. Names, cards and rings are the page's own,
 * drawn only for what is on screen, from pools. Moves run under 300 ms with
 * anime.js, and at once after a key press or for a reader who asked for less
 * motion.
 */
import {animate, type JSAnimation} from "animejs"

import {createCamera} from "../../camera"
import {createCanvasIsland} from "../../canvas_island"
import {EASE_OUT, SLOW, byPointer, lastInputByPointer, still} from "../../hooks/motion/shared"
import {watchTheme} from "../../theme"
import {tone} from "../../theme_tone"
import {
  CARD_ROOM,
  CLUSTER,
  cardsFrom,
  cellAt,
  clusterAt,
  columnsFor,
  eachRun,
  find,
  fleetRadius,
  geometry,
  petalAt,
  rowsFor,
  spiralIndex,
  stepAt,
  strengths,
  type Found,
  type Geometry,
  type Strengths,
} from "./layout"
import {BLOCKS, GLOW, MAX_SHAPES, POINTS, SHAPE_FLOATS, type FieldRenderer} from "./renderer"

/** Asks the page, and hears its answer when it gives one. */
export type Ask = <Reply>(event: string, payload: object, reply?: (reply: Reply) => void) => void

export type FieldStage = {
  /** The page drew the field's element again: its rows, window or kind may have changed. */
  update(): void
  /** The fleet's work was counted again: what is on screen is read again. */
  changed(): void
  pause(): void
  resume(): void
  destroy(): void
}

type Row = {readonly project: string; title: string}
type Cell = [at: number, project: string, kind: string, changes: number, things: number]
type Card = {
  readonly id: string
  readonly kind: string
  readonly what: string
  readonly project: string
  readonly title: string
  readonly who: string | null
  readonly at: number
  readonly changes: number
  readonly path: string
  readonly live: boolean
}
type Counts = [changes: number, things: number]

const HOUR = 3600
// The hours a read of a year's hours covers, under the page's thousand a read.
const TILE = 720
// A cluster's width on screen, in CSS pixels, from which its hours are read,
// and a cell's from which a year is read by the hour and things are read.
const HOURS_AT = 180
const FINE_AT = 10
const THINGS_AT = 90
// A cluster brought into view fills this much of the screen's shorter side.
const FRAME = 0.86
const STEP = 2
// How long an unanswered question waits before it is asked again, in ms.
const RETRY = 15_000
const KEEP_TILES = 120
const KEEP_HOURS = 160
// The most points one hour shows before its things are read.
const MOST_POINTS = 200
// Names and rings on screen at once.
const MOST_NAMES = 48
const MOST_RINGS = 96
const SLOT_KEY = 100_000
// What has been asked for, by number: the window's kinds, today, the last
// hour, a project's window (its rank), a tile of a year's hours, an hour's things.
const WHOLE = 9e9
const todayKey = (day: number) => 3e9 + day
const latelyKey = (hour: number) => 6e9 + hour
const tileKey = (rank: number, tile: number) => -(rank * 100 + tile + 1)
const hourKey = (rank: number, index: number) => rank * 10_000 + index
const thingsKey = (rank: number, index: number) => -(1e9 + hourKey(rank, index))
const kindKey = (rank: number, slot: number, index: number) => (rank * 16 + slot) * 10_000 + index

const clamp = (value: number, low: number, high: number) => Math.min(high, Math.max(low, value))
const heat = (count: number, most: number) => (most > 0 ? Math.log1p(count) / Math.log1p(most) : 0)

const DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
const two = (value: number) => String(value).padStart(2, "0")
const dayLabel = (seconds: number) => {
  const at = new Date(seconds * 1000)
  return `${DAYS[at.getUTCDay()]} ${at.getUTCDate()} ${MONTHS[at.getUTCMonth()]} ${at.getUTCFullYear()}`
}
const hourLabel = (seconds: number) => `${dayLabel(seconds)}, ${two(new Date(seconds * 1000).getUTCHours())}:00 UTC`
const clockOf = (ms: number) => {
  const at = new Date(ms)
  return `${two(at.getUTCHours())}:${two(at.getUTCMinutes())}`
}
const counted = (count: number, one: string, many: string) =>
  count === 1 ? `1 ${one}` : `${count.toLocaleString("en")} ${many}`

export function createFieldStage(root: HTMLElement, ask: Ask): FieldStage {
  const stage = root.querySelector<HTMLElement>("[data-field-stage]")!
  const surface = root.querySelector<HTMLElement>("[data-field-surface]")!
  const names = root.querySelector<HTMLElement>("[data-field-names]")!
  const deck = root.querySelector<HTMLElement>("[data-field-cards]")!
  const tip = root.querySelector<HTMLElement>("[data-field-tip]")!
  const level = root.querySelector<HTMLOutputElement>("[data-field-level]")!
  const said = root.querySelector<HTMLElement>("[data-field-said]")!
  const context = root.querySelector<HTMLElement>("[data-field-context]")!
  const events = new AbortController()
  const listen = {signal: events.signal}

  // What the page drew: the rows, the kinds, the window and the kind of work shown.
  let rowsJson = ""
  let rows: Row[] = []
  let rankOf = new Map<string, number>()
  let kinds: string[] = []
  let kindNames: string[] = []
  let slotOf = new Map<string, number>()
  let shown = ""
  let windowName = "year"
  let from = 0
  let to = 0
  let shape: Geometry = geometry(1, 1)
  // A year's hours are read a tile at a time; a shorter window's with the rest of it.
  let midHours = 1

  // The counts read so far.
  let generation = 0
  const asking = new Map<number, number>()
  const stale = new Set<number>()
  // Each kind of each project over the window, by rank: changes then things, a pair a kind.
  const whole = new Map<number, number[]>()
  // Changes today and yesterday, by rank and kind; and the projects that
  // worked in the last two hours, with the last such hour of each kind.
  const today = new Map<number, number[]>()
  const latelyRanks: number[] = []
  const latelyHours: number[][] = []
  // The window by day (a year) or by hour, by rank, then by kind and bucket.
  const mid = new Map<number, Map<number, Counts>>()
  // A year by the hour, a tile at a time, by rank and tile, then kind and hour.
  const fine = new Map<number, Map<number, Counts>>()
  // The hours whose things are read, and their things by kind, oldest first.
  const hoursRead: number[] = []
  const things = new Map<number, Card[]>()
  let mostWhole = 0
  let mostToday = 0
  let mostMid = 0
  let mostFine = 0
  let mostThing = 0
  let latelyRead = -1
  let pinned: string | undefined
  let pinPending = false
  let focusPinned = false

  // The view.
  let width = 0
  let height = 0
  let moving: JSAnimation | undefined
  let keyed = false
  let hovering = false
  const cursor: Found = {rank: 0, slot: -1, index: -1}
  // The cluster whose ring is still finding its newest work, or -1.
  let aiming = -1
  const hover: Found = {rank: 0, slot: -1, index: -1}
  const scratch: Found = {rank: 0, slot: -1, index: -1}
  const point: [number, number] = [0, 0]
  const corner: [number, number] = [0, 0]
  const strength: Strengths = {glow: 0, blocks: 0, dots: 0}

  // The three layers' instances, and what each was last built for.
  const data = [0, 1, 2].map(() => new Float32Array(MAX_SHAPES * SHAPE_FLOATS))
  const built = [0, 1, 2].map(() => ({count: 0, left: 0, top: 0, right: 0, bottom: 0, x: 0, y: 0, fine: false, dirty: true}))

  let island: {renderer(): FieldRenderer | undefined; nudge(): void} | undefined

  const instant = () => still(root) || !lastInputByPointer()
  const clusterPx = () => CLUSTER * camera.zoom
  const cellPx = () => shape.cell * camera.zoom
  const screenX = (x: number) => (x - camera.x) * camera.zoom + width / 2
  const screenY = (y: number) => (y - camera.y) * camera.zoom + height / 2
  const fleetZoom = () => Math.min(width, height) / (2 * fleetRadius(rows.length) * 1.04)
  const nowSeconds = () => Math.floor(Date.now() / 1000)
  const holdsNow = () => {
    const now = nowSeconds()
    return now >= from && now < to
  }

  const camera = createCamera(surface, {
    onFrame: () => render(),
    onTap: (x, y, target) => tap(x, y, target),
    reducedMotion: () => still(root),
    zoom: {min: 0.005, max: 20_000},
  })

  // ——— Reading ——————————————————————————————————————————————————————————

  function readPage() {
    const nextShown = `${root.dataset.kind}|${root.dataset.from}|${root.dataset.to}|${root.dataset.kinds}`
    const fresh = nextShown !== shown
    if (fresh) {
      shown = nextShown
      forget()
      rows = []
      rankOf = new Map()
      rowsJson = ""
      const read = JSON.parse(root.dataset.kinds ?? "[]") as [string, string][]
      kinds = read.map(([kind]) => kind)
      kindNames = read.map(([, name]) => name)
      slotOf = new Map(kinds.map((kind, slot) => [kind, slot]))
      windowName = root.dataset.window ?? "year"
      from = Number(root.dataset.from)
      to = Number(root.dataset.to)
      shape = geometry(Math.round((to - from) / HOUR), Math.max(1, kinds.length))
      midHours = windowName === "year" ? 24 : 1
    }
    const json = root.dataset.rows ?? "[]"
    if (json !== rowsJson) {
      rowsJson = json
      // New projects join after the ones shown; a cluster never moves under the reader.
      for (const [project, title] of JSON.parse(json) as [string, string, number][]) {
        const rank = rankOf.get(project)
        if (rank === undefined) {
          rankOf.set(project, rows.length)
          rows.push({project, title})
        } else rows[rank].title = title
      }
      built[GLOW].dirty = true
    }
    return fresh
  }

  // Asks once, again after a while without an answer, and again once what it read is stale.
  function asked(key: number, loaded: boolean) {
    if (loaded && !stale.has(key)) return true
    const now = performance.now()
    if (now - (asking.get(key) ?? -Infinity) < RETRY) return true
    asking.set(key, now)
    return false
  }

  function answered(key: number) {
    asking.delete(key)
    stale.delete(key)
  }

  const cells = (span: string, start: number, end: number, project: string | null, key: number, take: (cells: Cell[]) => void) => {
    const asOf = generation
    ask<{cells: Cell[]}>("atlas_field_cells", {span, from: start, to: end, project}, reply => {
      if (asOf !== generation) return
      answered(key)
      take(reply.cells)
      render()
    })
  }

  // Each project's kinds over the whole window, and its work today and in the last hour.
  function readFleet() {
    if (!asked(WHOLE, whole.size > 0 || mostWhole < 0)) {
      cells(windowName, from, to, null, WHOLE, read => {
        whole.clear()
        mostWhole = 0
        for (const [, project, kind, changes, count] of read) {
          const rank = rankOf.get(project)
          const slot = slotOf.get(kind)
          if (rank === undefined || slot === undefined) continue
          const pairs = whole.get(rank) ?? new Array<number>(kinds.length * 2).fill(0)
          pairs[slot * 2] += changes
          pairs[slot * 2 + 1] += count
          whole.set(rank, pairs)
          mostWhole = Math.max(mostWhole, pairs[slot * 2])
        }
        // An empty window is read once, not asked for again.
        if (whole.size === 0) mostWhole = -1
        built[GLOW].dirty = true
      })
    }
    if (!holdsNow()) return
    const hour = Math.floor(nowSeconds() / HOUR) * HOUR
    const day = Math.floor(hour / 86_400) * 86_400
    if (!asked(todayKey(day), today.size > 0 || mostToday < 0)) {
      cells("day", day - 86_400, day + 86_400, null, todayKey(day), read => {
        today.clear()
        mostToday = 0
        for (const [, project, kind, changes] of read) {
          const rank = rankOf.get(project)
          const slot = slotOf.get(kind)
          if (rank === undefined || slot === undefined) continue
          const counts = today.get(rank) ?? new Array<number>(kinds.length).fill(0)
          counts[slot] += changes
          today.set(rank, counts)
          mostToday = Math.max(mostToday, counts[slot])
        }
        if (today.size === 0) mostToday = -1
        built[GLOW].dirty = true
      })
    }
    if (!asked(latelyKey(hour), latelyRead === hour)) {
      cells("hour", hour - HOUR, hour + HOUR, null, latelyKey(hour), read => {
        latelyRead = hour
        latelyRanks.length = 0
        latelyHours.length = 0
        for (const [at, project, kind] of read) {
          const rank = rankOf.get(project)
          const slot = slotOf.get(kind)
          if (rank === undefined || slot === undefined) continue
          let at_ = latelyRanks.indexOf(rank)
          if (at_ < 0) {
            at_ = latelyRanks.push(rank) - 1
            latelyHours.push(new Array<number>(kinds.length).fill(-1))
          }
          latelyHours[at_][slot] = Math.max(latelyHours[at_][slot], Math.floor((at - from) / HOUR))
        }
        aim()
      })
    }
  }

  // The window of a project on screen, by day for a year and by hour otherwise.
  function readMid(rank: number) {
    if (asked(rank, mid.has(rank))) return
    cells(midHours === 24 ? "day" : "hour", from, to, rows[rank].project, rank, read => {
      const buckets = new Map<number, Counts>()
      for (const [at, , kind, changes, count] of read) {
        const slot = slotOf.get(kind)
        if (slot === undefined) continue
        buckets.set(slot * SLOT_KEY + Math.floor((at - from) / HOUR), [changes, count])
        mostMid = Math.max(mostMid, changes)
      }
      mid.delete(rank)
      mid.set(rank, buckets)
      built[BLOCKS].dirty = true
      built[POINTS].dirty = true
      aim()
    })
  }

  // A tile of a year's hours of a project on screen.
  function readFine(rank: number, tile: number) {
    const key = tileKey(rank, tile)
    if (asked(key, fine.has(key))) return
    const start = from + tile * TILE * HOUR
    cells("hour", start, Math.min(to, start + TILE * HOUR), rows[rank].project, key, read => {
      const hours = new Map<number, Counts>()
      for (const [at, , kind, changes, count] of read) {
        const slot = slotOf.get(kind)
        if (slot === undefined) continue
        hours.set(slot * SLOT_KEY + Math.floor((at - from) / HOUR), [changes, count])
        mostFine = Math.max(mostFine, changes)
      }
      fine.delete(key)
      fine.set(key, hours)
      if (fine.size > KEEP_TILES) fine.delete(fine.keys().next().value!)
      built[BLOCKS].dirty = true
      built[POINTS].dirty = true
      aim()
    })
  }

  // The things of an hour of a project on screen, every kind together.
  function readThings(rank: number, index: number) {
    const key = thingsKey(rank, index)
    if (asked(key, hoursRead.includes(hourKey(rank, index)))) return
    const asOf = generation
    ask<{things: Card[]}>("atlas_field_things", {project: rows[rank].project, at: from + index * HOUR}, reply => {
      if (asOf !== generation) return
      answered(key)
      forgetHour(rank, index)
      // Read newest first; laid out in the order they happened, each kind in its own patch.
      const read = [...reply.things].sort((a, b) => a.at - b.at || (a.id < b.id ? -1 : 1))
      for (const card of read) {
        const slot = slotOf.get(card.kind)
        if (slot === undefined) continue
        mostThing = Math.max(mostThing, card.changes)
        const kept = things.get(kindKey(rank, slot, index))
        if (kept) kept.push(card)
        else things.set(kindKey(rank, slot, index), [card])
      }
      hoursRead.push(hourKey(rank, index))
      if (hoursRead.length > KEEP_HOURS) {
        const oldest = hoursRead.shift()!
        forgetHour(Math.floor(oldest / 10_000), oldest % 10_000)
      }
      built[POINTS].dirty = true
      centrePinned()
      render()
    })
  }

  function forgetHour(rank: number, index: number) {
    const at = hoursRead.indexOf(hourKey(rank, index))
    if (at >= 0) hoursRead.splice(at, 1)
    for (let slot = 0; slot < kinds.length; slot++) things.delete(kindKey(rank, slot, index))
  }

  // An hour's counts at the finest detail read: by the hour, or the day holding it.
  function hourCounts(rank: number, slot: number, index: number): Counts | undefined {
    if (midHours === 1) return mid.get(rank)?.get(slot * SLOT_KEY + index)
    return fine.get(tileKey(rank, Math.floor(index / TILE)))?.get(slot * SLOT_KEY + index)
  }

  const hourRead = (rank: number, index: number) =>
    midHours === 1 ? mid.has(rank) : fine.has(tileKey(rank, Math.floor(index / TILE)))

  const kindOf = (rank: number, slot: number, index: number) => things.get(kindKey(rank, slot, index))

  // ——— Drawing ——————————————————————————————————————————————————————————

  function put(layer: number, count: number, x: number, y: number, w: number, h: number, value: number) {
    if (count >= MAX_SHAPES) return count
    const out = data[layer]
    const at = count * SHAPE_FLOATS
    out[at] = x
    out[at + 1] = y
    out[at + 2] = w
    out[at + 3] = h
    out[at + 4] = value
    return count + 1
  }

  // The changes of a cluster's kinds in `counts`, taking every `step`th from `first`.
  const sum = (counts: readonly number[] | undefined, first: number, step: number) => {
    let total = 0
    for (let at = first; counts && at < counts.length; at += step) total += counts[at]
    return total
  }

  // Each cluster as a halo, larger and brighter the more it worked lately
  // (today and yesterday, or over a past window); its kinds as glows inside
  // it; and where each worked today, at its newest hours.
  function buildGlow() {
    const layer = built[GLOW]
    const span = shape.side * shape.cell
    const lead = holdsNow() ? Math.floor((nowSeconds() - from) / HOUR) : -1
    let mostLately = 0
    for (const rank of whole.keys()) {
      mostLately = Math.max(mostLately, lead >= 0 ? sum(today.get(rank), 0, 1) : sum(whole.get(rank), 0, 2))
    }
    let count = 0
    for (const [rank, pairs] of whole) {
      clusterAt(rank, point)
      const lately = heat(lead >= 0 ? sum(today.get(rank), 0, 1) : sum(pairs, 0, 2), mostLately)
      const halo = CLUSTER * (0.8 + 1.4 * lately)
      count = put(GLOW, count, point[0] - halo / 2, point[1] - halo / 2, halo, halo, lately)
      for (let slot = 0; slot < kinds.length; slot++) {
        const changes = pairs[slot * 2]
        if (changes <= 0) continue
        petalAt(shape, slot, corner)
        const wide = span * 1.3
        const x = point[0] + corner[0] * shape.cell - wide / 2
        const y = point[1] + corner[1] * shape.cell - wide / 2
        count = put(GLOW, count, x, y, wide, wide, heat(changes, mostWhole) * 0.85)
        const recent = today.get(rank)?.[slot] ?? 0
        if (recent > 0 && lead >= 0) {
          cellAt(shape, rank, slot, lead, corner)
          const share = heat(recent, mostToday)
          const hot = span * (0.3 + 0.45 * share)
          count = put(GLOW, count, corner[0] - hot / 2, corner[1] - hot / 2, hot, hot, 0.55 + 0.45 * share)
        }
      }
    }
    layer.count = count
    layer.x = 0
    layer.y = 0
    layer.dirty = false
    island?.renderer()?.shapes(GLOW, data[GLOW], count)
  }

  // The view's bounds, half a screen past each edge, in world units.
  function region(layer: (typeof built)[number]) {
    const across = width / camera.zoom
    const down = height / camera.zoom
    layer.left = camera.x - across
    layer.right = camera.x + across
    layer.top = camera.y - down
    layer.bottom = camera.y + down
    layer.x = Math.round(camera.x)
    layer.y = Math.round(camera.y)
  }

  const clusterIn = (rank: number, layer: (typeof built)[number]) => {
    clusterAt(rank, point)
    const half = CLUSTER / 2
    return point[0] + half >= layer.left && point[0] - half <= layer.right && point[1] + half >= layer.top && point[1] - half <= layer.bottom
  }

  // The blocks written so far, and where the next runs go: their patch's
  // corner on the layer, and their value.
  let blocks = 0
  let runX = 0
  let runY = 0
  let runValue = 0
  const putRun = (x: number, y: number, w: number, h: number) => {
    const cell = shape.cell
    blocks = put(BLOCKS, blocks, runX + x * cell, runY + y * cell, w * cell, h * cell, runValue)
  }

  // Each kind's patch of the projects near the view: the ground of its hours,
  // then its work, by day or by hour as read and as the zoom asks.
  function buildBlocks() {
    const layer = built[BLOCKS]
    region(layer)
    layer.fine = midHours === 24 && cellPx() >= FINE_AT
    blocks = 0
    const cell = shape.cell
    for (let rank = 0; rank < rows.length; rank++) {
      if (!clusterIn(rank, layer)) continue
      const cx = point[0]
      const cy = point[1]
      runValue = -1
      for (let slot = 0; slot < kinds.length; slot++) {
        petalAt(shape, slot, corner)
        runX = cx + corner[0] * cell - layer.x
        runY = cy + corner[1] * cell - layer.y
        eachRun(0, shape.hours, putRun)
      }
      const buckets = mid.get(rank)
      if (!buckets) continue
      for (const [key, [changes]] of buckets) {
        const slot = Math.floor(key / SLOT_KEY)
        const start = key % SLOT_KEY
        // A year's day gives way to its hours once they are read.
        if (layer.fine && fine.has(tileKey(rank, Math.floor(start / TILE)))) continue
        petalAt(shape, slot, corner)
        runX = cx + corner[0] * cell - layer.x
        runY = cy + corner[1] * cell - layer.y
        runValue = heat(changes, mostMid)
        eachRun(start, Math.min(shape.hours, start + midHours), putRun)
      }
      if (!layer.fine) continue
      for (let tile = 0; tile * TILE < shape.hours; tile++) {
        const hours = fine.get(tileKey(rank, tile))
        if (!hours) continue
        for (const [key, [changes]] of hours) {
          const slot = Math.floor(key / SLOT_KEY)
          cellAt(shape, rank, slot, key % SLOT_KEY, corner)
          if (corner[0] < layer.left || corner[0] > layer.right || corner[1] < layer.top || corner[1] > layer.bottom) continue
          blocks = put(BLOCKS, blocks, corner[0] - cell / 2 - layer.x, corner[1] - cell / 2 - layer.y, cell, cell, heat(changes, mostFine))
        }
      }
    }
    layer.count = blocks
    layer.dirty = false
    island?.renderer()?.shapes(BLOCKS, data[BLOCKS], blocks)
  }

  // Calls `visit` with each hour cell of the projects on screen inside `layer`'s bounds.
  function eachCell(
    left: number,
    top: number,
    right: number,
    bottom: number,
    visit: (rank: number, slot: number, index: number, x: number, y: number) => void,
  ) {
    const cell = shape.cell
    const ring = (shape.side - 1) / 2
    for (let rank = 0; rank < rows.length; rank++) {
      clusterAt(rank, point)
      const cx = point[0]
      const cy = point[1]
      const half = CLUSTER / 2
      if (cx + half < left || cx - half > right || cy + half < top || cy - half > bottom) continue
      for (let slot = 0; slot < kinds.length; slot++) {
        petalAt(shape, slot, corner)
        const mx = cx + corner[0] * cell
        const my = cy + corner[1] * cell
        const x0 = Math.max(-ring, Math.floor((left - mx) / cell + 0.5))
        const x1 = Math.min(ring, Math.ceil((right - mx) / cell - 0.5))
        const y0 = Math.max(-ring, Math.floor((top - my) / cell + 0.5))
        const y1 = Math.min(ring, Math.ceil((bottom - my) / cell - 0.5))
        for (let gy = y0; gy <= y1; gy++) {
          for (let gx = x0; gx <= x1; gx++) {
            const index = spiralIndex(gx, gy)
            if (index < shape.hours) visit(rank, slot, index, mx + gx * cell, my + gy * cell)
          }
        }
      }
    }
  }

  // A point for each thing of each hour near the view: the thing's own once
  // its hour is read, square for an item and round for a notebook.
  function buildPoints() {
    const layer = built[POINTS]
    region(layer)
    let count = 0
    const cell = shape.cell
    eachCell(layer.left, layer.top, layer.right, layer.bottom, (rank, slot, index, x, y) => {
      const read = kindOf(rank, slot, index)
      const counts = hourCounts(rank, slot, index)
      const total = read?.length ?? Math.min(counts?.[1] ?? 0, MOST_POINTS)
      if (total === 0) return
      const columns = columnsFor(total)
      const w = cell / columns
      const h = cell / rowsFor(total)
      const left = x - cell / 2 - layer.x
      const top = y - cell / 2 - layer.y
      const notebook = kinds[slot] === "notebook" ? 2 : 0
      const shared = heat(counts?.[0] ?? total, midHours === 1 ? mostMid : mostFine)
      for (let at = 0; at < total; at++) {
        const value = read ? heat(read[at].changes, mostThing) : shared
        count = put(POINTS, count, left + (at % columns) * w, top + Math.floor(at / columns) * h, w, h, value + notebook)
      }
    })
    layer.count = count
    layer.dirty = false
    island?.renderer()?.shapes(POINTS, data[POINTS], count)
  }

  const outside = (layer: (typeof built)[number]) => {
    const across = width / 2 / camera.zoom
    const down = height / 2 / camera.zoom
    return camera.x - across < layer.left || camera.x + across > layer.right || camera.y - down < layer.top || camera.y + down > layer.bottom
  }

  function paint() {
    const renderer = island?.renderer()
    if (!renderer) return
    strengths(clusterPx(), cellPx(), strength)
    renderer.view(camera.x, camera.y, camera.zoom)
    renderer.layer(GLOW, built[GLOW].x, built[GLOW].y, strength.glow)
    renderer.layer(BLOCKS, built[BLOCKS].x, built[BLOCKS].y, strength.blocks)
    renderer.layer(POINTS, built[POINTS].x, built[POINTS].y, strength.dots)
    island!.nudge()
  }

  // ——— Reading what is on screen ————————————————————————————————————————

  function readOnScreen() {
    readFleet()
    if (clusterPx() < HOURS_AT) return
    const left = camera.x - width / 2 / camera.zoom
    const right = camera.x + width / 2 / camera.zoom
    const top = camera.y - height / 2 / camera.zoom
    const bottom = camera.y + height / 2 / camera.zoom
    const half = CLUSTER / 2
    const cell = shape.cell
    const ring = (shape.side - 1) / 2
    for (let rank = 0; rank < rows.length; rank++) {
      clusterAt(rank, point)
      const cx = point[0]
      const cy = point[1]
      if (cx + half < left || cx - half > right || cy + half < top || cy - half > bottom) continue
      readMid(rank)
      if (midHours !== 24 || cellPx() < FINE_AT) continue
      // The hours of each patch on screen lie between the rings it crosses.
      let first = shape.hours
      let last = 0
      for (let slot = 0; slot < kinds.length; slot++) {
        petalAt(shape, slot, corner)
        const x0 = (left - cx) / cell - corner[0]
        const x1 = (right - cx) / cell - corner[0]
        const y0 = (top - cy) / cell - corner[1]
        const y1 = (bottom - cy) / cell - corner[1]
        if (x1 < -ring - 0.5 || x0 > ring + 0.5 || y1 < -ring - 0.5 || y0 > ring + 0.5) continue
        const near = Math.max(0, x0 > 0 ? x0 : x1 < 0 ? -x1 : 0, y0 > 0 ? y0 : y1 < 0 ? -y1 : 0)
        const far = Math.min(ring, Math.max(Math.abs(x0), Math.abs(x1), Math.abs(y0), Math.abs(y1)))
        const inner = Math.max(0, Math.round(near))
        first = Math.min(first, inner === 0 ? 0 : (2 * inner - 1) ** 2)
        last = Math.max(last, Math.min(shape.hours, (2 * Math.ceil(far) + 1) ** 2))
      }
      for (let tile = Math.floor(first / TILE); tile * TILE < last; tile++) readFine(rank, tile)
    }
    if (cellPx() < THINGS_AT) return
    eachCell(left, top, right, bottom, readHour)
  }

  function readHour(rank: number, slot: number, index: number) {
    const counts = hourCounts(rank, slot, index)
    if (counts && counts[1] > 0 && cellPx() >= cardsFrom(Math.min(counts[1], MOST_POINTS)) * 0.5) readThings(rank, index)
  }

  // ——— Names, rings and cards ———————————————————————————————————————————

  const pool = (className: string, tag = "span") => {
    const els: HTMLElement[] = []
    let used = 0
    return {
      start() {
        used = 0
      },
      take() {
        let el = els[used]
        if (!el) {
          el = names.appendChild(document.createElement(tag))
          el.className = className
          els.push(el)
        }
        if (el.hidden) el.hidden = false
        used += 1
        return el
      },
      finish() {
        for (let index = used; index < els.length; index++) if (!els[index].hidden) els[index].hidden = true
      },
    }
  }
  const titles = pool("atlas-field__name")
  const kindTitles = pool("atlas-field__name atlas-field__name--kind")
  const rings = pool("atlas-field__now")
  const ring = names.appendChild(document.createElement("span"))
  ring.className = "atlas-field__ring"
  ring.hidden = true
  const boxes = new Float64Array(MOST_NAMES * 4)

  const text = (el: HTMLElement, words: string) => {
    if (el.textContent !== words) el.textContent = words
  }
  // Where each name and ring stands, so it is moved only when it moves.
  const stands = new Map<HTMLElement, [number, number, number]>()
  const move = (el: HTMLElement, x: number, y: number, size = 0) => {
    const px = Math.round(x)
    const py = Math.round(y)
    const ps = Math.round(size)
    let at = stands.get(el)
    if (at && at[0] === px && at[1] === py && at[2] === ps) return
    if (!at) stands.set(el, (at = [0, 0, 0]))
    at[0] = px
    at[1] = py
    if (ps !== at[2]) {
      at[2] = ps
      el.style.width = el.style.height = `${ps}px`
    }
    el.style.transform = `translate3d(${px}px, ${py}px, 0)`
  }

  // Projects' names under their clusters, the busiest first, none over another.
  function placeNames() {
    titles.start()
    kindTitles.start()
    const size = clusterPx()
    let placed = 0
    if (size < 900) {
      for (let rank = 0; rank < rows.length && placed < MOST_NAMES; rank++) {
        clusterAt(rank, point)
        const x = screenX(point[0])
        const y = screenY(point[1] + CLUSTER / 2) + 4
        if (x < -80 || x > width + 80 || y < -20 || y > height + 20) continue
        const el = titles.take()
        text(el, rows[rank].title)
        const w = Math.min(el.offsetWidth || 120, 160)
        const left = x - w / 2
        const right = x + w / 2
        const bottom = y + 18
        let free = true
        for (let other = 0; other < placed && free; other++) {
          const at = other * 4
          free = right < boxes[at] || left > boxes[at + 2] || bottom < boxes[at + 1] || y > boxes[at + 3]
        }
        if (!free) {
          el.hidden = true
          continue
        }
        boxes[placed * 4] = left
        boxes[placed * 4 + 1] = y
        boxes[placed * 4 + 2] = right
        boxes[placed * 4 + 3] = bottom
        placed += 1
        move(el, left, y)
      }
    }
    // Each kind's name above its patch, once a patch has room for one, while
    // the patch's corner is on screen; past that the corner box names it.
    const petalPx = shape.side * cellPx()
    if (size >= 260 && petalPx >= 64) {
      for (let rank = 0; rank < rows.length; rank++) {
        clusterAt(rank, point)
        const cx = point[0]
        const cy = point[1]
        for (let slot = 0; slot < kinds.length; slot++) {
          petalAt(shape, slot, corner)
          const x = screenX(cx + (corner[0] - shape.side / 2) * shape.cell)
          const y = screenY(cy + (corner[1] - shape.side / 2) * shape.cell)
          if (x < 0 || x > width || y < 18 || y > height) continue
          const el = kindTitles.take()
          text(el, kindNames[slot])
          move(el, x, y - 18)
        }
      }
    }
    titles.finish()
    kindTitles.finish()
  }

  // A ring where work happened in the last hour: around a cluster from far
  // away, at the hour itself closer in.
  function placeRings() {
    rings.start()
    let used = 0
    const size = clusterPx()
    for (let entry = 0; entry < latelyRanks.length && used < MOST_RINGS; entry++) {
      const rank = latelyRanks[entry]
      const last = latelyHours[entry]
      if (size < 260) {
        clusterAt(rank, point)
        const wide = Math.max(size * 1.2, 14)
        const x = screenX(point[0]) - wide / 2
        const y = screenY(point[1]) - wide / 2
        if (x > width || y > height || x + wide < 0 || y + wide < 0) continue
        move(rings.take(), x, y, wide)
        used += 1
        continue
      }
      for (let slot = 0; slot < last.length && used < MOST_RINGS; slot++) {
        if (last[slot] < 0 || last[slot] >= shape.hours) continue
        cellAt(shape, rank, slot, last[slot], point)
        const wide = Math.max(cellPx() * 1.6, 14)
        const x = screenX(point[0]) - wide / 2
        const y = screenY(point[1]) - wide / 2
        if (x > width || y > height || x + wide < 0 || y + wide < 0) continue
        move(rings.take(), x, y, wide)
        used += 1
      }
    }
    rings.finish()
  }

  // The ring on the cluster or hour under the pointer, or the keyboard's.
  function placeRing() {
    const spot = hovering ? hover : keyed && document.activeElement === stage ? cursor : undefined
    if (!spot) {
      if (!ring.hidden) ring.hidden = true
      return
    }
    let wide: number
    if (spot.slot < 0) {
      clusterAt(spot.rank, point)
      wide = clusterPx() + 8
    } else {
      cellAt(shape, spot.rank, spot.slot, spot.index, point)
      wide = Math.max(cellPx(), 6) + 4
    }
    if (ring.hidden) ring.hidden = false
    move(ring, screenX(point[0]) - wide / 2, screenY(point[1]) - wide / 2, wide)
  }

  // Each card on screen, by its hour's own entry: a thing changed in two hours has a card in each.
  const placed = new Map<Card, HTMLElement>()
  const spots = new Map<HTMLElement, [number, number]>()
  const spare: HTMLElement[] = []
  const seen = new Map<Card, number>()
  let pass = 0
  // Cards on screen this frame.
  let cardsShown = 0

  const makeCard = () => {
    const el = document.createElement("div")
    el.className = "atlas-card"
    el.innerHTML =
      '<p class="atlas-card__top"><span class="atlas-card__mark" aria-hidden="true"></span>' +
      '<span class="atlas-card__what"></span><span class="atlas-card__at"></span></p>' +
      '<a class="atlas-card__title"></a>'
    const link = el.querySelector<HTMLAnchorElement>(".atlas-card__title")!
    // A drag that starts on a title moves the field rather than carrying the link off,
    // and the cards are reached from the field, in reading order, not by Tab alone.
    link.draggable = false
    link.tabIndex = -1
    deck.append(el)
    return el
  }

  const fill = (el: HTMLElement, card: Card) => {
    el.dataset.id = card.id
    el.dataset.source = card.live ? "graph" : "notebook"
    el.querySelector(".atlas-card__what")!.textContent = card.who ? `${card.what} · ${card.who}` : card.what
    el.querySelector(".atlas-card__at")!.textContent = clockOf(card.at)
    const link = el.querySelector<HTMLAnchorElement>(".atlas-card__title")!
    link.textContent = card.title
    link.title = card.title
    link.href = card.path
    if (card.live) {
      link.dataset.phxLink = "patch"
      link.dataset.phxLinkState = "push"
    } else {
      delete link.dataset.phxLink
      delete link.dataset.phxLinkState
    }
  }

  const place = (el: HTMLElement, x: number, y: number) => {
    const spot = spots.get(el)
    const px = Math.round(x)
    const py = Math.round(y)
    if (spot && spot[0] === px && spot[1] === py) return
    el.style.transform = `translate3d(${px}px, ${py}px, 0)`
    if (spot) {
      spot[0] = px
      spot[1] = py
    } else spots.set(el, [px, py])
  }

  function takeCard(card: Card, x: number, y: number) {
    let el = placed.get(card)
    if (!el) {
      el = spare.pop() ?? makeCard()
      el.hidden = false
      fill(el, card)
      placed.set(card, el)
    }
    el.toggleAttribute("data-pinned", card.id === pinned)
    el.toggleAttribute("data-now", card.at >= Date.now() - HOUR * 1000)
    place(el, x, y)
    seen.set(card, pass)
    cardsShown += 1
    if (card.id === pinned && focusPinned) {
      focusPinned = false
      el.querySelector<HTMLAnchorElement>(".atlas-card__title")!.focus({preventScroll: true})
    }
  }

  // The cards of one hour of one kind on screen, once its cell holds them all.
  function placeCell(rank: number, slot: number, index: number, x: number, y: number) {
    const read = kindOf(rank, slot, index)
    const size = cellPx()
    if (!read || read.length === 0 || size < cardsFrom(read.length)) return
    const columns = columnsFor(read.length)
    const w = size / columns
    const h = size / rowsFor(read.length)
    const sx = screenX(x) - size / 2
    const sy = screenY(y) - size / 2
    for (let at = 0; at < read.length; at++) {
      const cx = sx + (at % columns) * w + (w - CARD_ROOM[0]) / 2 + 3
      const cy = sy + Math.floor(at / columns) * h + (h - CARD_ROOM[1]) / 2 + 3
      if (cx > width || cy > height || cx + CARD_ROOM[0] < 0 || cy + CARD_ROOM[1] < 0) continue
      takeCard(read[at], cx, cy)
    }
  }

  // A card no longer on screen goes back to the pool; if it had the focus, the field takes it.
  function sweep(el: HTMLElement, card: Card) {
    if (seen.get(card) === pass) return
    if (el.contains(document.activeElement)) stage.focus({preventScroll: true})
    el.hidden = true
    placed.delete(card)
    seen.delete(card)
    spare.push(el)
  }

  function placeCards() {
    pass += 1
    cardsShown = 0
    if (cellPx() >= CARD_ROOM[0]) {
      const across = width / 2 / camera.zoom
      const down = height / 2 / camera.zoom
      eachCell(camera.x - across, camera.y - down, camera.x + across, camera.y + down, placeCell)
    }
    placed.forEach(sweep)
  }

  // ——— Words ———————————————————————————————————————————————————————————

  // The cluster or hour of `spot`, in words, with what it holds.
  function describe(spot: Found): [string, string, string] {
    const row = rows[spot.rank]
    if (!row) return ["", "", ""]
    if (spot.slot < 0) {
      const pairs = whole.get(spot.rank)
      let [changes, count] = [0, 0]
      for (let slot = 0; pairs && slot < kinds.length; slot++) {
        changes += pairs[slot * 2]
        count += pairs[slot * 2 + 1]
      }
      return [row.title, "", changes ? `${counted(changes, "change", "changes")} · ${counted(count, "thing", "things")}` : "Nothing changed"]
    }
    const byHour = hourRead(spot.rank, spot.index) && (midHours === 1 || cellPx() >= FINE_AT)
    const start = byHour ? spot.index : Math.floor(spot.index / midHours) * midHours
    const counts = byHour
      ? hourCounts(spot.rank, spot.slot, start)
      : mid.get(spot.rank)?.get(spot.slot * SLOT_KEY + start)
    const when = byHour ? hourLabel(from + start * HOUR) : dayLabel(from + start * HOUR)
    const loaded = byHour || mid.has(spot.rank)
    const holds = !loaded ? "" : counts ? `${counted(counts[0], "change", "changes")} · ${counted(counts[1], "thing", "things")}` : "Nothing changed"
    return [`${row.title} · ${kindNames[spot.slot]}`, when, holds]
  }

  const tipTitle = tip.appendChild(document.createElement("strong"))
  const tipWhen = tip.appendChild(document.createElement("span"))
  const tipCounts = tip.appendChild(document.createElement("span"))

  function showTip(x: number, y: number) {
    const [title, when, holds] = describe(hover)
    text(tipTitle, title)
    text(tipWhen, when)
    tipWhen.hidden = when === ""
    text(tipCounts, holds)
    tip.hidden = false
    const [w, h] = [tip.offsetWidth, tip.offsetHeight]
    const left = x + 14 + w > width ? x - 14 - w : x + 14
    const top = clamp(y + 14, 4, Math.max(4, height - h - 4))
    tip.style.transform = `translate3d(${Math.round(left)}px, ${Math.round(top)}px, 0)`
  }

  const hideTip = () => {
    if (!tip.hidden) tip.hidden = true
    if (hovering) {
      hovering = false
      placeRing()
    }
  }

  const say = (spot: Found) => {
    said.textContent = describe(spot).filter(Boolean).join(", ")
  }

  // ——— Each frame ——————————————————————————————————————————————————————

  let stepWord = ""
  // The cluster and kind named at the top left: rank, then slot.
  let contextRank = -1
  let contextSlot = -2

  function render() {
    if (!width || !height || rows.length === 0) return
    const low = fleetZoom() / 3
    camera.zoom = clamp(camera.zoom, low, Math.max(low * 2, (cardsFrom(MOST_POINTS) * 1.2) / shape.cell))
    const reach = fleetRadius(rows.length)
    camera.x = clamp(camera.x, -reach, reach)
    camera.y = clamp(camera.y, -reach, reach)

    readOnScreen()
    strengths(clusterPx(), cellPx(), strength)
    if (built[GLOW].dirty) buildGlow()
    if (strength.blocks > 0 && (built[BLOCKS].dirty || outside(built[BLOCKS]) || built[BLOCKS].fine !== (midHours === 24 && cellPx() >= FINE_AT))) {
      buildBlocks()
    }
    if (strength.dots > 0 && (built[POINTS].dirty || outside(built[POINTS]))) buildPoints()

    placeNames()
    placeRings()
    placeRing()
    placeCards()

    const word = stepAt(clusterPx(), cellPx(), cardsShown > 0)
    if (word !== stepWord) level.value = stepWord = word
    // Inside a cluster, the project and kind at the middle of the view.
    const inside = clusterPx() >= 260 && find(shape, rows.length, camera.x, camera.y, scratch)
    const rank = inside ? scratch.rank : -1
    const slot = inside ? scratch.slot : -2
    if (rank !== contextRank || slot !== contextSlot) {
      contextRank = rank
      contextSlot = slot
      context.textContent = rank < 0 ? "" : slot >= 0 ? `${rows[rank].title} · ${kindNames[slot]}` : rows[rank].title
      context.hidden = rank < 0
    }
    paint()
  }

  // ——— Moving ——————————————————————————————————————————————————————————

  function stop() {
    moving?.pause()
    moving = undefined
  }

  // Moves to a point and a zoom, gliding in under 300 ms or at once: the zoom
  // eases by its ratio, and the point moves across the screen as evenly as
  // the zoom allows.
  function go(x: number, y: number, zoom: number, glide: boolean) {
    stop()
    if (!glide || still(root)) {
      camera.jumpTo(x, y, zoom)
      render()
      return
    }
    const [fromX, fromY, fromZoom] = [camera.x, camera.y, camera.zoom]
    const offsetX = (x - fromX) * fromZoom
    const offsetY = (y - fromY) * fromZoom
    const ratio = Math.log(zoom / fromZoom)
    const state = {t: 0}
    moving = animate(state, {
      t: 1,
      duration: SLOW,
      ease: EASE_OUT,
      onUpdate: () => {
        const at = fromZoom * Math.exp(ratio * state.t)
        camera.jumpTo(x - (offsetX * (1 - state.t)) / at, y - (offsetY * (1 - state.t)) / at, at)
      },
      onComplete: () => {
        moving = undefined
      },
    })
  }

  // The zoom at which an hour's things show as cards.
  function cardsZoom(spot: Found) {
    const count = kindOf(spot.rank, spot.slot, spot.index)?.length ?? hourCounts(spot.rank, spot.slot, spot.index)?.[1] ?? 1
    return (cardsFrom(clamp(count, 1, MOST_POINTS)) * 1.08) / shape.cell
  }

  // A closer look: a cluster fills the screen; an hour grows a step at a
  // time until its things show as cards.
  function lookInto(spot: Found, glide: boolean) {
    if (spot.slot < 0) {
      clusterAt(spot.rank, point)
      go(point[0], point[1], (Math.min(width, height) * FRAME) / CLUSTER, glide)
      return
    }
    cellAt(shape, spot.rank, spot.slot, spot.index, point)
    const goal = cardsZoom(spot)
    go(point[0], point[1], camera.zoom * 6 < goal ? camera.zoom * 6 : Math.max(goal, camera.zoom), glide)
  }

  // The window's newest hour: the one under way while the window holds now.
  const lastHour = () => (holdsNow() ? clamp(Math.floor((nowSeconds() - from) / HOUR), 0, shape.hours - 1) : shape.hours - 1)

  // A kind's newest hour with work in it, as far as read: from the last two
  // hours, else from the window by the hour, or by the day and then its hours.
  function newestHour(rank: number, slot: number) {
    const lately = latelyRanks.indexOf(rank)
    if (lately >= 0 && latelyHours[lately][slot] >= 0) return latelyHours[lately][slot]
    let newest = -1
    mid.get(rank)?.forEach(([changes], key) => {
      if (changes > 0 && Math.floor(key / SLOT_KEY) === slot) newest = Math.max(newest, key % SLOT_KEY)
    })
    if (newest < 0) return lastHour()
    const end = Math.min(newest + midHours - 1, lastHour())
    for (let index = end; index >= newest; index--) if ((hourCounts(rank, slot, index)?.[0] ?? 0) > 0) return index
    return end
  }

  // The ring goes inside the cluster in view: to its busiest kind's newest
  // work, and stays aimed there as the cluster's reads arrive, until moved.
  function enterCluster() {
    if (find(shape, rows.length, camera.x, camera.y, scratch)) cursor.rank = scratch.rank
    const pairs = whole.get(cursor.rank)
    let busiest = -1
    cursor.slot = 0
    for (let slot = 0; pairs && slot < kinds.length; slot++) {
      if (pairs[slot * 2] <= busiest) continue
      busiest = pairs[slot * 2]
      cursor.slot = slot
    }
    cursor.index = newestHour(cursor.rank, cursor.slot)
    aiming = cursor.rank
  }

  function aim() {
    if (aiming < 0 || cursor.rank !== aiming || cursor.slot < 0) return
    const index = newestHour(aiming, cursor.slot)
    if (index === cursor.index) return
    cursor.index = index
    if (document.activeElement === stage) say(cursor)
  }

  const local = (clientX: number, clientY: number) => {
    const box = surface.getBoundingClientRect()
    return [clientX - box.left - surface.clientLeft, clientY - box.top - surface.clientTop] as const
  }

  // The cluster or hour at a point of the surface: the cluster alone from far away.
  function spotAt(x: number, y: number, into: Found) {
    const wx = camera.x + (x - width / 2) / camera.zoom
    const wy = camera.y + (y - height / 2) / camera.zoom
    if (!find(shape, rows.length, wx, wy, into)) return false
    if (clusterPx() < 260) into.slot = -1
    return into.slot >= 0 || clusterPx() < 260
  }

  const tapped: Found = {rank: 0, slot: -1, index: -1}

  function tap(clientX: number, clientY: number, target: EventTarget | null) {
    if (target instanceof Element && target.closest("a, button")) return
    const [x, y] = local(clientX, clientY)
    if (spotAt(x, y, tapped)) lookInto(tapped, !instant())
  }

  // ——— Listening ———————————————————————————————————————————————————————

  // The ring's next stop in a direction: the nearest cluster that way, or the next hour on screen.
  function step(dx: number, dy: number) {
    if (clusterPx() >= 260 && cursor.slot < 0) return enterCluster()
    if (cursor.slot < 0) {
      clusterAt(cursor.rank, point)
      const [ox, oy] = point
      let best = -1
      let bestScore = Infinity
      for (let rank = 0; rank < rows.length; rank++) {
        if (rank === cursor.rank) continue
        clusterAt(rank, point)
        const vx = point[0] - ox
        const vy = point[1] - oy
        const along = vx * dx + vy * dy
        if (along <= 0) continue
        const across = Math.abs(vx * dy - vy * dx)
        const score = along + 2 * across
        if (score < bestScore) {
          bestScore = score
          best = rank
        }
      }
      if (best >= 0) cursor.rank = best
      cursor.slot = -1
      return
    }
    cellAt(shape, cursor.rank, cursor.slot, cursor.index, point)
    for (let hop = 1; hop <= shape.gap + 1; hop++) {
      if (!find(shape, rows.length, point[0] + dx * hop * shape.cell, point[1] + dy * hop * shape.cell, scratch)) return
      if (scratch.rank !== cursor.rank) return
      if (scratch.slot >= 0) {
        cursor.slot = scratch.slot
        cursor.index = scratch.index
        return
      }
    }
  }

  // Brings the keyboard's ring into view, at once.
  function reveal() {
    if (cursor.slot < 0) clusterAt(cursor.rank, point)
    else cellAt(shape, cursor.rank, cursor.slot, cursor.index, point)
    const x = screenX(point[0])
    const y = screenY(point[1])
    if (x < 24 || x > width - 24 || y < 24 || y > height - 24) camera.jumpTo(point[0], point[1])
    render()
  }

  function keydown(event: KeyboardEvent) {
    if (event.altKey || event.ctrlKey || event.metaKey) return
    const card = event.target instanceof Element ? event.target.closest<HTMLElement>(".atlas-card") : null
    if (card) return cardKey(event, card)
    if (event.target !== stage) return
    keyed = true
    stop()
    if (clusterPx() < 260) cursor.slot = -1
    const moves: Record<string, [number, number]> = {
      ArrowLeft: [-1, 0],
      ArrowRight: [1, 0],
      ArrowUp: [0, -1],
      ArrowDown: [0, 1],
    }
    const toward = moves[event.key]
    if (toward) {
      event.preventDefault()
      aiming = -1
      step(toward[0], toward[1])
      reveal()
      say(cursor)
    } else if (event.key === "+" || event.key === "=" || event.key === "-" || event.key === "_") {
      event.preventDefault()
      const factor = event.key === "+" || event.key === "=" ? STEP : 1 / STEP
      if (cursor.slot < 0) clusterAt(cursor.rank, point)
      else cellAt(shape, cursor.rank, cursor.slot, cursor.index, point)
      const box = surface.getBoundingClientRect()
      camera.zoomBy(factor, box.left + screenX(point[0]), box.top + screenY(point[1]))
      if (clusterPx() < 260) cursor.slot = -1
      say(cursor)
    } else if (event.key === "Enter") {
      event.preventDefault()
      if (cursor.slot < 0 && clusterPx() >= 260) enterCluster()
      const read = cursor.slot >= 0 ? kindOf(cursor.rank, cursor.slot, cursor.index) : undefined
      const first = read && cellPx() >= cardsFrom(read.length) ? placed.get(read[0]) : undefined
      if (first) {
        first.querySelector<HTMLAnchorElement>(".atlas-card__title")!.focus({preventScroll: true})
        return
      }
      const cluster = cursor.slot < 0
      lookInto(cursor, false)
      // A cluster looked into: the ring goes inside it.
      if (cluster) {
        enterCluster()
        render()
      }
      say(cursor)
    }
  }

  // Tab and Shift+Tab step through the cards on screen in reading order and
  // leave at either end; Escape goes back to the field.
  function cardKey(event: KeyboardEvent, card: HTMLElement) {
    if (event.key === "Escape") {
      // The field's own: no open section elsewhere on the page closes with it.
      event.preventDefault()
      event.stopPropagation()
      stage.focus({preventScroll: true})
      return
    }
    if (event.key !== "Tab") return
    const order = [...placed.values()]
      .filter(el => !el.hidden)
      .sort((a, b) => spots.get(a)![1] - spots.get(b)![1] || spots.get(a)![0] - spots.get(b)![0])
    const next = order[order.indexOf(card) + (event.shiftKey ? -1 : 1)]
    if (!next) return
    event.preventDefault()
    next.querySelector<HTMLAnchorElement>(".atlas-card__title")!.focus({preventScroll: true})
  }

  function pointermove(event: PointerEvent) {
    const [x, y] = local(event.clientX, event.clientY)
    if (event.pointerType === "touch" || surface.hasAttribute("data-dragging")) return hideTip()
    if (event.target instanceof Element && event.target.closest(".atlas-card")) return hideTip()
    if (!spotAt(x, y, hover)) return hideTip()
    hovering = true
    showTip(x, y)
    placeRing()
  }

  function clicked(event: MouseEvent) {
    const target = event.target instanceof Element ? event.target : null
    const zoom = target?.closest<HTMLElement>("[data-field-zoom]")
    if (!zoom) return
    const factor = zoom.dataset.fieldZoom === "in" ? STEP : 1 / STEP
    go(camera.x, camera.y, camera.zoom * factor, byPointer(event) && !still(root))
  }

  // A thing chosen in the strip beside the field: its card, in its hour of its
  // kind of its project, in the middle of the field however narrow.
  function focusThing(event: Event) {
    const {id, project, kind, at} = (event as CustomEvent<{id: string; project: string; kind: string; at: number}>).detail
    const rank = rankOf.get(project)
    const slot = slotOf.get(kind)
    const index = Math.floor((at / 1000 - from) / HOUR)
    if (rank === undefined || slot === undefined || index < 0 || index >= shape.hours) return
    pinned = id
    pinPending = true
    focusPinned = !lastInputByPointer()
    aiming = -1
    cursor.rank = rank
    cursor.slot = slot
    cursor.index = index
    cellAt(shape, rank, slot, index, point)
    go(point[0], point[1], Math.max(camera.zoom, cardsZoom(cursor)), !instant())
    centrePinned()
  }

  // Once the chosen thing's hour is read, its own card comes to the middle.
  function centrePinned() {
    if (!pinPending || cursor.slot < 0) return
    const read = kindOf(cursor.rank, cursor.slot, cursor.index)
    const at = read?.findIndex(card => card.id === pinned) ?? -1
    if (!read || at < 0) return
    pinPending = false
    const columns = columnsFor(read.length)
    cellAt(shape, cursor.rank, cursor.slot, cursor.index, point)
    const zoom = Math.max(camera.zoom, (cardsFrom(read.length) * 1.08) / shape.cell)
    const x = point[0] - shape.cell / 2 + ((at % columns) + 0.5) * (shape.cell / columns)
    const y = point[1] - shape.cell / 2 + (Math.floor(at / columns) + 0.5) * (shape.cell / rowsFor(read.length))
    go(x, y, zoom, !instant())
  }

  stage.addEventListener("keydown", keydown, listen)
  root.addEventListener("click", clicked, listen)
  root.addEventListener("atlas:focus", focusThing, listen)
  surface.addEventListener("pointermove", pointermove, listen)
  surface.addEventListener("pointerleave", hideTip, listen)
  surface.addEventListener(
    "pointerdown",
    () => {
      keyed = false
      stop()
    },
    {...listen, capture: true},
  )
  surface.addEventListener(
    "wheel",
    () => {
      stop()
      hideTip()
    },
    {...listen, passive: true, capture: true},
  )
  stage.addEventListener("focus", () => placeRing(), listen)
  stage.addEventListener("blur", () => placeRing(), listen)

  // ——— The page ————————————————————————————————————————————————————————

  function forget() {
    generation += 1
    aiming = -1
    asking.clear()
    stale.clear()
    whole.clear()
    today.clear()
    latelyRanks.length = 0
    latelyHours.length = 0
    latelyRead = -1
    mid.clear()
    fine.clear()
    things.clear()
    hoursRead.length = 0
    mostWhole = mostToday = mostMid = mostFine = mostThing = 0
    for (const layer of built) layer.dirty = true
  }

  function frameFleet() {
    if (!width || !height || rows.length === 0) return
    cursor.rank = 0
    cursor.slot = -1
    aiming = -1
    camera.jumpTo(0, 0, fleetZoom())
  }

  function update() {
    if (readPage()) frameFleet()
    render()
  }

  function changed() {
    stale.add(WHOLE)
    stale.add(todayKey(Math.floor(nowSeconds() / 86_400) * 86_400))
    latelyRead = -1
    for (const rank of mid.keys()) stale.add(rank)
    for (const key of fine.keys()) stale.add(key)
    for (const key of hoursRead) stale.add(thingsKey(Math.floor(key / 10_000), key % 10_000))
    asking.clear()
    render()
  }

  // The last hour moves on with the clock: its rings are read again each hour.
  let hourShown = Math.floor(Date.now() / 3_600_000)
  const clock = window.setInterval(() => {
    const hour = Math.floor(Date.now() / 3_600_000)
    if (hour === hourShown) return
    hourShown = hour
    built[GLOW].dirty = true
    render()
  }, 60_000)

  let framed = false
  const resize = new ResizeObserver(() => {
    width = surface.clientWidth
    height = surface.clientHeight
    if (!framed && width && height && rows.length) {
      framed = true
      frameFleet()
    }
    for (const layer of built) layer.dirty = true
    render()
  })
  resize.observe(surface)

  if (!navigator.gpu) surface.dataset.fieldStill = "true"
  const controller = createCanvasIsland<FieldRenderer>(surface, {}, {
    canvasSelector: "[data-field-canvas]",
    readyFlag: "fieldReady",
    // The field is the page's content, so it is drawn for every reader.
    motionSensitive: false,
    continuous: false,
    browserLoad: async (canvas, size, lost) => {
      const {createFieldRenderer} = await import("./renderer")
      return createFieldRenderer(canvas, size, lost)
    },
    interact: ({renderer, nudge, onReady}) => {
      island = {renderer, nudge}
      const retone = () => {
        renderer()?.tones(
          tone(surface, "--atlas-heat-empty"),
          tone(surface, "--atlas-heat-1"),
          tone(surface, "--atlas-heat-2"),
          tone(surface, "--atlas-heat-3"),
        )
        nudge()
      }
      onReady(() => {
        retone()
        built.forEach((layer, index) => renderer()?.shapes(index, data[index], layer.count))
        paint()
      })
      const forgetTheme = watchTheme(retone)
      return () => {
        forgetTheme()
        island = undefined
        // The GPU is not going to draw: the page says so, and the List has it all.
        surface.dataset.fieldStill = "true"
      }
    },
  })
  controller.mount()

  update()

  return {
    update,
    changed,
    pause: () => controller.pause(),
    resume() {
      controller.resume()
      changed()
    },
    destroy() {
      stop()
      window.clearInterval(clock)
      events.abort()
      resize.disconnect()
      camera.destroy()
      controller.destroy()
    },
  }
}
