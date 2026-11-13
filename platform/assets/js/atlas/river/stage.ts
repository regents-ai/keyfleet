/**
 * The Atlas as a river: time runs left to right and each project is a band
 * as thick as its work at that time, stacked into one stream with the
 * busiest in the middle; past the dozen busiest, the rest run together in
 * one band that opens. Inside a band the workspace's work is solid and its
 * notebooks striped. Zooming moves from a year of weeks to a month of days
 * and a day of hours; there, the band under the pointer takes the height and
 * opens into a lane for each kind of work, the lanes resolve into a mark for
 * each thing changed, and the marks into cards linking to each thing's page.
 *
 * Nothing the fleet ever did reaches the browser at once. The page answers
 * `atlas_river` for the counts near the view a tile at a time (`cells`), the
 * chosen band's kinds of work (`lanes`) and the things it changed in an hour
 * (`items`), and, once the view settles, names the window in view in the
 * address (`atlas_window`), so the window chosen at the top and the strip of
 * the most active things beside the picture follow it. When the fleet's work
 * is counted again the page says so (`changed`), and what is on screen is
 * read again in place.
 *
 * The wheel and a pinch zoom through time about the pointer; with Shift the
 * wheel gives the band under the pointer the height instead. Dragging moves
 * through time, and up and down the lanes when they are taller than the
 * picture. Pressing a band gives it the height, pressing it again looks
 * closer. With the keyboard, the arrow keys move a ring from band to band
 * and bucket to bucket, plus and minus zoom about it, Enter gives the band
 * the height and then looks closer, and among the cards moves to the first
 * one; Tab steps through the cards in reading order, Escape leaves them, and
 * then lets the band go. Choosing a thing in the strip brings its card in.
 *
 * The stream is drawn on the GPU (`./renderer`), two layers of it so a level
 * fades into the next, and only redrawn when something moved. The times along
 * the top, the names and the cards are the page's own, the cards drawn only
 * inside an hour and only those on screen, from a pool. A band opens in under
 * 300 ms with anime.js, and at once after a key press or for a reader who
 * asked for less motion; everything else follows the zoom itself.
 */
import {animate, type JSAnimation} from "animejs"

import {createCamera} from "../../camera"
import {createCanvasIsland} from "../../canvas_island"
import {BASE, EASE_OUT, SLOW, byPointer, lastInputByPointer, still} from "../../hooks/motion/shared"
import {watchTheme} from "../../theme"
import {tone} from "../../theme_tone"
import {MAX_LANE_PIECES, MAX_MARKS, MAX_PIECES, type RiverRenderer, type RiverView} from "./renderer"
import {
  LANE_FLOATS,
  MARK_FLOATS,
  PIECE_FLOATS,
  REST,
  ALT,
  alternate,
  anchors,
  bounds,
  columns,
  insideOut,
  jitter,
  lanePieces,
  pieces,
  row,
  scales,
  type Series,
  type Stack,
} from "./stream"
import {
  DAYS_FROM,
  EPOCH,
  HOUR,
  HOURS_FROM,
  LEVELS,
  bucketLabel,
  bucketOf,
  clockOf,
  contextOf,
  dateOf,
  eachTick,
  hourOf,
  levelAt,
  msOf,
  nextContext,
  windowFor,
  windowOf,
  type Window,
} from "./time"

/** Asks the page, and hears its answer when it gives one. */
export type Ask = <Reply>(event: string, payload: object, reply?: (reply: Reply) => void) => void

export type RiverStage = {
  /** The page drew the picture's element again: its rows, window or kind may have changed. */
  update(): void
  /** The fleet's work was counted again: what is on screen is read again. */
  changed(): void
  pause(): void
  resume(): void
  destroy(): void
}

type Row = {readonly project: string; title: string}
type Band = {readonly project: string | null; readonly title: string}
type Cell = {
  readonly project: string
  readonly changes: number
  readonly things: number
  readonly actors: number
  readonly notebooks: number
}
type Tile = Map<number, Cell[]>
type KindCell = {readonly kind: string; readonly changes: number; readonly things: number; readonly actors: number}
type KindTile = Map<number, KindCell[]>
type Item = {
  readonly id: string
  readonly kind: string
  readonly what: string
  readonly title: string
  readonly who: string | null
  readonly at: number
  readonly changes: number
  readonly path: string
  readonly live: boolean
  spread: number
}
type Most = {total: number; chosen: number; others: number}
type Layer = {
  level: number
  base: number
  first: number
  n: number
  from: number
  to: number
  count: number
  dirty: boolean
  ko: number
  kf: number
  stack: Stack
}
type Spot = {place: number; lane: number; mark: number; at: number}

// The band of times along the top, and the room above and below the stream, in CSS pixels.
const AXIS = 32
const PAD = 14
const ZOOM = {min: 0.02, max: 2400}
// The busiest bands shown on their own before the rest run together, and how
// many more show on their own once the rest are opened.
const FOLD = 12
const MORE = 48
// How much of the height a chosen band takes.
const SHARE = 0.78
// The zoom, in CSS pixels an hour, at which the band under the pointer opens
// into lanes, the lanes into marks and the marks into cards, each over the
// stretch up to its pair, and at which a thing is looked at.
const LANES_FROM = 40
const LANES_IN = 64
const MARKS_FROM = 120
const MARKS_IN = 190
const CARDS_FROM = 420
const CARDS_IN = 560
const LOOK = 640
// Below this zoom a band the zoom opened lets go again.
const LANES_CLOSE = 28
const STEP = 2
// How long the view rests before the window in view is named in the address, in ms.
const SETTLE = 320
// How long an unanswered question waits before it is asked again, in ms.
const RETRY = 15_000
const KEEP_TILES = 40
const KEEP_HOURS = 48
// A lane's height at the least, the strip its marks run along beside the
// cards, and a card and the room around it, in CSS pixels.
const LANE = 40
const STRIP = 26
const CARD_WIDTH = 184
const CARD_HEIGHT = 72
const CARD_GAP = 6
const CARD_PAD = 8
const LANE_CARDS = STRIP + CARD_HEIGHT + 2 * CARD_PAD
// How far in from a card's left edge its own mark sits (its border, padding
// and half the mark), so the card stands under its thing's mark on the lane.
const CARD_MARK = 15
// How much of a card must be out from under the times, or the bottom edge, for it to show.
const CARD_SEEN = 16
// The most cards and the rest's chip a lane holds in one hour.
const ROW = columns(ZOOM.max, CARD_WIDTH, CARD_GAP, CARD_PAD) + 1
// The least thickness a band shows its name at, and the room from either
// edge its name stands in, in CSS pixels.
const NAMED = 18
const NAME_ROOM = 72
// The room a mark held beside the name at the left edge needs, in CSS pixels.
const HELD_ROOM = 72
// How far past now and back before it the picture may be moved, in hours.
const AHEAD = 7 * 24
const BEHIND = 20 * 8_784

const clamp = (value: number, low: number, high: number) => Math.min(high, Math.max(low, value))
const ramp = (value: number, from: number, to: number) => clamp((value - from) / (to - from), 0, 1)
const counted = (value: number, one: string, many: string) =>
  value === 1 ? `1 ${one}` : `${value.toLocaleString("en")} ${many}`

export function createRiverStage(root: HTMLElement, ask: Ask): RiverStage {
  const stage = root.querySelector<HTMLElement>("[data-atlas-stage]")!
  const surface = root.querySelector<HTMLElement>("[data-atlas-surface]")!
  const names = root.querySelector<HTMLElement>("[data-atlas-names]")!
  const axis = root.querySelector<HTMLElement>("[data-atlas-axis]")!
  const deck = root.querySelector<HTMLElement>("[data-atlas-cards]")!
  const ring = root.querySelector<HTMLElement>("[data-atlas-ring]")!
  const tip = root.querySelector<HTMLElement>("[data-atlas-tip]")!
  const level = root.querySelector<HTMLOutputElement>("[data-atlas-level]")!
  const toggle = root.querySelector<HTMLButtonElement>("[data-atlas-more]")!
  const said = root.querySelector<HTMLElement>("[data-atlas-said]")!
  const events = new AbortController()
  const listen = {signal: events.signal}

  // What the page drew: the kind of work shown, the rows and the window named in the address.
  let kind = ""
  let rowsJson = ""
  let rows: Row[] = []
  let restOpen = false
  let named: {window: Window; start: number} | undefined
  let asked: {window: Window; start: number} | undefined

  // The bands, busiest first, where each stands in the stack, and the series
  // of the stream bottom to top.
  let bands: Band[] = []
  let rankOf = new Map<string, number>()
  let placeOf: number[] = []
  let rankAt: number[] = []
  let series: Series[] = []
  let seriesOf = new Int32Array(0)
  let bandFlags: number[] = []
  // The chosen band's project, whether the zoom chose it, and how far it has opened.
  let chosen: string | null = null
  let chosenByZoom = false
  let zoomOpens = false
  const open = {value: 0}
  let opening: JSAnimation | undefined

  // The counts read so far: tiles of buckets by level, the chosen band's kinds
  // of work by tile, and the things it changed by hour.
  let generation = 0
  const tiles: Map<number, Tile>[] = [new Map(), new Map(), new Map()]
  const asking: Map<number, number>[] = [new Map(), new Map(), new Map()]
  const stale: Set<number>[] = [new Set(), new Set(), new Set()]
  const most: Most[] = [0, 1, 2].map(() => ({total: 0, chosen: 0, others: 0}))
  const laneTiles = new Map<string, KindTile>()
  const askingLanes = new Map<string, number>()
  const staleLanes = new Set<string>()
  const laneNames = new Map<string, string>()
  let kinds: string[] = []
  let laneOf = new Map<string, number>()
  let laneMost = 0
  const items = new Map<string, Item[]>()
  const askingItems = new Map<string, number>()
  const staleItems = new Set<string>()
  // Each hour's things by the lane they run in, the chosen thing first.
  const grouped = new Map<string, Map<number, Item[]>>()
  let pinned: string | undefined
  let focusPinned = false
  let revealKind: string | undefined

  // The view.
  let width = 0
  let height = 0
  let shift = 0
  let lastZoom = 0
  let moving: JSAnimation | undefined
  let keyed = false
  // Where the pointer last was over the picture, for the band the zoom opens.
  let pointerX = -1
  let pointerY = -1
  const cursor: Spot = {place: 0, lane: 0, mark: -1, at: 0}
  const hover: Spot = {place: -1, lane: -1, mark: -1, at: 0}
  let hovering = false

  // Two layers of the stream: the level shown in front, and the one fading out behind it.
  const data = [new Float32Array(MAX_PIECES * PIECE_FLOATS), new Float32Array(MAX_PIECES * PIECE_FLOATS)]
  const emptyStack = (): Stack => ({values: new Float64Array(0), n: 0, series: [], bandFlags: []})
  const layers: Layer[] = [0, 1].map(() => ({
    level: -1,
    base: 0,
    first: 0,
    n: 0,
    from: 0,
    to: 0,
    count: 0,
    dirty: true,
    ko: 1,
    kf: 1,
    stack: emptyStack(),
  }))
  let scratch = new Float64Array(0)
  let front = 0
  const fade = {value: 1}
  let fading: JSAnimation | undefined
  let waiting = false

  // The chosen band's lanes and its things' marks.
  const laneData = new Float32Array(MAX_LANE_PIECES * LANE_FLOATS)
  let laneValues = new Float64Array(0)
  const lanesBuilt = {count: 0, base: 0, from: 0, to: 0, dirty: true}
  const markData = new Float32Array(MAX_MARKS * MARK_FLOATS)
  const marked: Item[] = []
  const marksBuilt = {count: 0, base: 0, from: 0, to: 0, dirty: true}

  // The shape the stream is drawn in this frame, and what the GPU is told, each made once.
  const shape = {ko: 1, kf: 1, open: 0, lanes: 0, region: 0}
  const view: RiverView = {
    hour: 0,
    zoom: 1,
    middle: 0,
    top: AXIS,
    open: 0,
    lanes: 0,
    region: 0,
    lane: LANE,
    line: LANE / 2,
    laneScale: 1,
    marks: 0,
    cards: 0,
    spread: 0,
    hoverBand: -1,
    hoverLane: -1,
    hoverMark: -1,
    chosen: -1,
  }
  let streamTop = AXIS + PAD
  let streamHeight = 1
  let bounded = new Float64Array(0)

  let island: {renderer(): RiverRenderer | undefined; nudge(): void} | undefined
  let settleTimer = 0
  let movedAt = 0

  const instant = () => still(root) || !lastInputByPointer()
  const screenX = (hour: number) => (hour - camera.x) * camera.zoom + width / 2
  const levelNow = () => levelAt(camera.zoom)
  const chosenRank = () => {
    const rank = chosen === null ? undefined : rankOf.get(chosen)
    return rank === undefined || bands[rank]?.project !== chosen ? -1 : rank
  }
  const chosenPlace = () => {
    const rank = chosenRank()
    return rank < 0 ? -1 : placeOf[rank]
  }
  // The middle of lane `lane`'s line, and its top, in CSS pixels up from the middle of the stream.
  const laneTop = (lane: number) => view.region / 2 - lane * view.lane
  const lineOf = (lane: number) => laneTop(lane) - view.line

  const camera = createCamera(surface, {
    onFrame: () => render(),
    onTap: (x, y, target) => tap(x, y, target),
    reducedMotion: () => still(root),
    zoom: ZOOM,
  })

  // ——— Bands ——————————————————————————————————————————————————————————————

  // The bands on screen, from the rows the page counted and whether the rest are open.
  function arrange() {
    // The keyboard stays on the same project as the bands change; it starts on the busiest.
    const held = rankAt[cursor.place] ?? 0
    const folds = rows.length > FOLD + 1
    const own = folds ? (restOpen ? Math.min(rows.length, FOLD + MORE) : FOLD) : rows.length
    bands = rows.slice(0, own).map(row => ({project: row.project, title: row.title}))
    const rest = rows.length - own
    if (rest > 0) bands.push({project: null, title: `${rest.toLocaleString("en")} more`})
    rankOf = new Map(rows.map((row, index) => [row.project, Math.min(index, own)]))
    placeOf = insideOut(bands.length)
    rankAt = new Array<number>(bands.length)
    placeOf.forEach((place, rank) => (rankAt[place] = rank))
    toggle.hidden = !folds
    toggle.setAttribute("aria-expanded", String(restOpen))
    toggle.textContent = restOpen ? "Fewer" : "More"
    if (chosen !== null && chosenRank() < 0) {
      chosen = null
      open.value = 0
    }
    cursor.place = bands.length ? placeOf[Math.min(held, bands.length - 1)] : 0
    stack()
  }

  // The series bottom to top, each band's notebooks on its side away from the
  // middle, and where each stands against the chosen band.
  function stack() {
    const middle = bands.length ? placeOf[0] : 0
    const picked = chosenPlace()
    series = []
    seriesOf = new Int32Array(bands.length * 2).fill(-1)
    bandFlags = new Array<number>(bands.length)
    for (let place = 0; place < bands.length; place++) {
      const rank = rankAt[place]
      bandFlags[place] = (bands[rank].project === null ? REST : 0) | (alternate(rank) ? ALT : 0)
      const where = picked < 0 || place < picked ? 0 : place === picked ? 1 : 2
      for (const notebook of place >= middle ? [false, true] : [true, false]) {
        if ((kind === "graph" && notebook) || (kind === "notebook" && !notebook)) continue
        seriesOf[place * 2 + (notebook ? 1 : 0)] = series.length
        series.push({band: place, notebook, place: where})
      }
    }
    if (scratch.length < series.length * 4) scratch = new Float64Array(series.length * 4)
    if (bounded.length < series.length * 2) bounded = new Float64Array(series.length * 2)
    for (const lvl of [0, 1, 2]) measure(lvl)
    for (const layer of layers) layer.dirty = true
    placeNamesFor()
  }

  function readRows() {
    const json = root.dataset.rows ?? "[]"
    if (json === rowsJson) return false
    rowsJson = json
    const read = (JSON.parse(json) as [string, string, number][]).map(([project, title]) => ({project, title}))
    // New rows join after the ones shown; a band never trades places under the reader.
    const known = new Map(rows.map(entry => [entry.project, entry]))
    for (const entry of read) {
      const was = known.get(entry.project)
      if (was) was.title = entry.title
      else rows.push(entry)
    }
    return true
  }

  // Gives the band of `rank` the height, or lets the chosen one go (-1), opening at once or in under 300 ms.
  function choose(rank: number, byZoom: boolean, glide: boolean) {
    opening?.pause()
    opening = undefined
    zoomOpens = false
    const project = rank >= 0 ? bands[rank]?.project ?? null : null
    if (project !== null && project !== chosen) {
      chosen = project
      open.value = 0
      kinds = []
      laneOf = new Map()
      laneMost = 0
      learnKinds(project)
      lanesBuilt.dirty = true
      marksBuilt.dirty = true
      grouped.clear()
      stack()
    }
    chosenByZoom = project !== null && byZoom
    const target = project !== null ? 1 : 0
    if (chosen === null) return
    const done = () => {
      opening = undefined
      if (target === 0) {
        chosen = null
        stack()
        render()
      }
    }
    if (!glide || still(root)) {
      open.value = target
      done()
      render()
      return
    }
    opening = animate(open, {value: target, duration: SLOW, ease: EASE_OUT, onUpdate: () => render(), onComplete: done})
  }

  // ——— Counts ——————————————————————————————————————————————————————————————

  // The busiest bucket of each level, the chosen band's busiest, and the rest's.
  function measure(lvl: number) {
    const rank = chosenRank()
    let total = 0
    let mine = 0
    let others = 0
    for (const tile of tiles[lvl].values()) {
      for (const cells of tile.values()) {
        let all = 0
        let own = 0
        for (const cell of cells) {
          const at = rankOf.get(cell.project)
          if (at === undefined) continue
          all += cell.changes
          if (at === rank) own += cell.changes
        }
        total = Math.max(total, all)
        mine = Math.max(mine, own)
        others = Math.max(others, all - own)
      }
    }
    const was = most[lvl]
    if (was.total === total && was.chosen === mine && was.others === others) return
    was.total = total
    was.chosen = mine
    was.others = others
    for (const layer of layers) if (layer.level === lvl) layer.dirty = true
  }

  function fetchTiles(lvl: number, from: number, to: number) {
    const {span, tile} = LEVELS[lvl]
    const now = performance.now()
    for (let index = Math.floor(from / tile); index <= Math.floor(to / tile); index++) {
      if (tiles[lvl].has(index) && !stale[lvl].has(index)) continue
      if (now - (asking[lvl].get(index) ?? -Infinity) < RETRY) continue
      asking[lvl].set(index, now)
      const asOf = generation
      const start = (EPOCH + index * tile * HOUR) / 1000
      ask<{cells: [number, string, number, number, number, number][]}>(
        "atlas_river",
        {read: "cells", span, from: start, to: start + tile * 3600},
        reply => {
          if (asOf !== generation) return
          asking[lvl].delete(index)
          stale[lvl].delete(index)
          const read: Tile = new Map()
          for (const [at, project, changes, things, actors, notebooks] of reply.cells) {
            const hour = hourOf(at * 1000)
            const cells = read.get(hour) ?? []
            cells.push({project, changes, things, actors, notebooks})
            read.set(hour, cells)
          }
          tiles[lvl].delete(index)
          tiles[lvl].set(index, read)
          if (tiles[lvl].size > KEEP_TILES) tiles[lvl].delete(tiles[lvl].keys().next().value!)
          measure(lvl)
          for (const layer of layers) if (layer.level === lvl) layer.dirty = true
          render()
        },
      )
    }
  }

  const loaded = (lvl: number, from: number, to: number) => {
    const {tile} = LEVELS[lvl]
    for (let index = Math.floor(from / tile); index <= Math.floor(to / tile); index++) {
      if (!tiles[lvl].has(index)) return false
    }
    return true
  }

  // One band's counts in the bucket of level `lvl` from `at`: a project's, or the rest's together.
  function countsAt(place: number, at: number, lvl: number) {
    const {tile} = LEVELS[lvl]
    const cells = tiles[lvl].get(Math.floor(at / tile))
    if (!cells) return undefined
    const rank = rankAt[place]
    let [changes, things, actors, notebooks] = [0, 0, 0, 0]
    for (const cell of cells.get(at) ?? []) {
      if (rankOf.get(cell.project) !== rank) continue
      changes += cell.changes
      things += cell.things
      actors = Math.max(actors, cell.actors)
      notebooks += cell.notebooks
    }
    return {changes, things, actors, notebooks, together: bands[rank]?.project === null}
  }

  // ——— Lanes and things ——————————————————————————————————————————————————————

  const laneKey = (project: string, index: number) => `${project}:${index}`

  function fetchLanes(project: string, from: number, to: number) {
    const {tile} = LEVELS[2]
    const now = performance.now()
    for (let index = Math.floor(from / tile); index <= Math.floor(to / tile); index++) {
      const key = laneKey(project, index)
      if (laneTiles.has(key) && !staleLanes.has(key)) continue
      if (now - (askingLanes.get(key) ?? -Infinity) < RETRY) continue
      askingLanes.set(key, now)
      const asOf = generation
      const start = (EPOCH + index * tile * HOUR) / 1000
      ask<{cells: [number, string, number, number, number][]; names: Record<string, string>}>(
        "atlas_river",
        {read: "lanes", from: start, to: start + tile * 3600, project},
        reply => {
          if (asOf !== generation) return
          askingLanes.delete(key)
          staleLanes.delete(key)
          const read: KindTile = new Map()
          for (const [at, kindOf, changes, things, actors] of reply.cells) {
            const hour = hourOf(at * 1000)
            const cells = read.get(hour) ?? []
            cells.push({kind: kindOf, changes, things, actors})
            read.set(hour, cells)
          }
          for (const [kindOf, name] of Object.entries(reply.names)) laneNames.set(kindOf, name)
          laneTiles.delete(key)
          laneTiles.set(key, read)
          if (laneTiles.size > KEEP_TILES) laneTiles.delete(laneTiles.keys().next().value!)
          if (project === chosen) learnKinds(project)
          lanesBuilt.dirty = true
          render()
        },
      )
    }
  }

  // The chosen band's lanes, top first: its notebooks, then its kinds of work
  // busiest first. A kind first seen later joins below, so no lane moves.
  function learnKinds(project: string) {
    const totals = new Map<string, number>()
    let top = 0
    for (const [key, tile] of laneTiles) {
      if (!key.startsWith(`${project}:`)) continue
      for (const cells of tile.values()) {
        for (const cell of cells) {
          totals.set(cell.kind, (totals.get(cell.kind) ?? 0) + cell.changes)
          top = Math.max(top, cell.changes)
        }
      }
    }
    laneMost = top
    const fresh = [...totals.keys()]
      .filter(name => !laneOf.has(name))
      .sort((a, b) => Number(b === "notebook") - Number(a === "notebook") || totals.get(b)! - totals.get(a)!)
    if (fresh.length === 0) return
    kinds = [...kinds, ...fresh]
    laneOf = new Map(kinds.map((name, lane) => [name, lane]))
    marksBuilt.dirty = true
    grouped.clear()
  }

  const itemKey = (project: string, hour: number) => `${project}:${hour}`

  function fetchItems(project: string, hour: number) {
    const key = itemKey(project, hour)
    if (items.has(key) && !staleItems.has(key)) return
    const now = performance.now()
    if (now - (askingItems.get(key) ?? -Infinity) < RETRY) return
    askingItems.set(key, now)
    const asOf = generation
    ask<{things: Omit<Item, "spread">[]}>("atlas_river", {read: "items", at: msOf(hour) / 1000, project}, reply => {
      if (asOf !== generation) return
      askingItems.delete(key)
      staleItems.delete(key)
      items.delete(key)
      // Read newest first; laid out in the order they happened.
      items.set(
        key,
        reply.things.reverse().map(thing => ({...thing, spread: jitter(thing.id)})),
      )
      if (items.size > KEEP_HOURS) {
        const oldest = items.keys().next().value!
        items.delete(oldest)
        grouped.delete(oldest)
      }
      grouped.delete(key)
      marksBuilt.dirty = true
      render()
    })
  }

  // An hour's things by lane, in the order they happened.
  function groupOf(key: string) {
    let byLane = grouped.get(key)
    if (byLane) return byLane
    byLane = new Map()
    for (const item of items.get(key) ?? []) {
      const lane = laneOf.get(item.kind)
      if (lane === undefined) continue
      const list = byLane.get(lane) ?? []
      list.push(item)
      byLane.set(lane, list)
    }
    if (items.has(key)) grouped.set(key, byLane)
    return byLane
  }

  // ——— Drawing the stream ————————————————————————————————————————————————————

  function build(slot: number) {
    const layer = layers[slot]
    const {hours: length, tile} = LEVELS[layer.level]
    const across = width / camera.zoom
    let first = bucketOf(camera.x - 1.5 * across, length) - length
    let last = bucketOf(camera.x + 1.5 * across, length) + length
    // As many knots as the pieces can hold, the middle of the view first.
    const room = Math.max(8, Math.floor(MAX_PIECES / Math.max(1, series.length)))
    if ((last - first) / length + 1 > room) {
      first = bucketOf(camera.x, length) - Math.floor(room / 2) * length
      last = first + (room - 1) * length
    }
    const n = (last - first) / length + 1
    const size = series.length * n
    let values = layer.stack.values
    if (values.length < size) values = new Float64Array(size)
    else values.fill(0, 0, size)

    const read = tiles[layer.level]
    for (let index = Math.floor(first / tile); index <= Math.floor(last / tile); index++) {
      const cells = read.get(index)
      if (!cells) continue
      for (const [at, bucket] of cells) {
        if (at < first || at > last) continue
        const knot = (at - first) / length
        for (const cell of bucket) {
          const rank = rankOf.get(cell.project)
          if (rank === undefined) continue
          const place = placeOf[rank]
          const graph = seriesOf[place * 2]
          const notebook = seriesOf[place * 2 + 1]
          if (graph >= 0) values[graph * n + knot] += cell.changes - cell.notebooks
          if (notebook >= 0) values[notebook * n + knot] += cell.notebooks
        }
      }
    }

    layer.stack = {values, n, series, bandFlags}
    layer.first = first
    layer.n = n
    layer.from = first + length
    layer.to = last - length
    layer.base = Math.round(camera.x)
    layer.count = pieces(layer.stack, first + length / 2 - layer.base, length, data[slot], MAX_PIECES, scratch)
    layer.dirty = false
    island?.renderer()?.pieces(slot, data[slot], layer.count)
    placeNamesFor()
  }

  // A new level comes in front of the one shown, and fades in once its counts are read.
  function switchLevel(lvl: number) {
    if (fade.value >= 0.5) front = 1 - front
    const layer = layers[front]
    layer.level = lvl
    layer.count = 0
    layer.dirty = true
    island?.renderer()?.pieces(front, data[front], 0)
    fading?.pause()
    fading = undefined
    fade.value = 0
    waiting = true
  }

  function fadeIn() {
    waiting = false
    if (instant()) {
      fade.value = 1
      return
    }
    fading = animate(fade, {value: 1, duration: BASE, ease: EASE_OUT, onUpdate: paint})
  }

  function buildLanes(project: string, from: number, to: number) {
    const lanes = kinds.length
    lanesBuilt.count = 0
    lanesBuilt.dirty = false
    lanesBuilt.base = Math.round(camera.x)
    if (lanes === 0) return
    const room = Math.max(8, Math.floor(MAX_LANE_PIECES / lanes))
    const across = to - from
    let first = Math.floor(from - across) - 1
    let last = Math.ceil(to + across) + 1
    if (last - first + 1 > room) {
      first = Math.floor(camera.x) - Math.floor(room / 2)
      last = first + room - 1
    }
    const n = last - first + 1
    if (laneValues.length < lanes * n) laneValues = new Float64Array(lanes * n)
    else laneValues.fill(0, 0, lanes * n)
    const {tile} = LEVELS[2]
    for (let index = Math.floor(first / tile); index <= Math.floor(last / tile); index++) {
      const cells = laneTiles.get(laneKey(project, index))
      if (!cells) continue
      for (const [at, bucket] of cells) {
        if (at < first || at > last) continue
        for (const cell of bucket) {
          const lane = laneOf.get(cell.kind)
          if (lane !== undefined) laneValues[(lanes - 1 - lane) * n + (at - first)] += cell.changes
        }
      }
    }
    const notebook = laneOf.get("notebook")
    lanesBuilt.from = first + 1
    lanesBuilt.to = last - 1
    lanesBuilt.count = lanePieces(
      laneValues,
      lanes,
      n,
      notebook === undefined ? -1 : lanes - 1 - notebook,
      first + 0.5 - lanesBuilt.base,
      1,
      laneData,
      MAX_LANE_PIECES,
    )
    island?.renderer()?.lanes(laneData, lanesBuilt.count)
  }

  function buildMarks(project: string, from: number, to: number) {
    const across = to - from
    const first = Math.floor(from - across / 2)
    const last = Math.min(first + 96, Math.floor(to + across / 2))
    let count = 0
    marksBuilt.base = Math.round(camera.x)
    for (let hour = first; hour <= last; hour++) {
      for (const item of items.get(itemKey(project, hour)) ?? []) {
        const lane = laneOf.get(item.kind)
        if (lane === undefined || count >= MAX_MARKS) continue
        const at = count * MARK_FLOATS
        markData[at] = hourOf(item.at) - marksBuilt.base
        markData[at + 1] = lane
        markData[at + 2] = item.spread
        markData[at + 3] = 7 + 2 * Math.sqrt(Math.min(item.changes, 16))
        markData[at + 4] = item.live ? 0 : 1
        markData[at + 5] = item.id === pinned ? 1 : 0
        marked[count] = item
        count += 1
      }
    }
    marked.length = count
    marksBuilt.count = count
    marksBuilt.from = first
    marksBuilt.to = last + 1
    marksBuilt.dirty = false
    island?.renderer()?.marks(markData, count)
  }

  // ——— Names ———————————————————————————————————————————————————————————————

  // Each band's name, where it is thickest in view, and each lane's.
  const nameEls: HTMLElement[] = []
  const nameAt: [number, number][] = []
  let anchorKnots = new Int32Array(0)
  let anchorMost = new Float64Array(0)
  let namesFor = -1
  const laneEls: HTMLElement[] = []
  const laneAt: number[] = []

  // The names stand again where their bands are thickest once the view rests.
  function placeNamesFor() {
    namesFor = -1
  }

  function pickAnchors() {
    const layer = layers[front]
    if (anchorKnots.length < bands.length) {
      anchorKnots = new Int32Array(bands.length)
      anchorMost = new Float64Array(bands.length)
    }
    const {hours: length} = LEVELS[Math.max(0, layer.level)]
    // Far enough in from either edge for a centred name to fit.
    const from = camera.x - (width / 2 - NAME_ROOM) / camera.zoom
    const to = camera.x + (width / 2 - NAME_ROOM) / camera.zoom
    const knot = (hour: number) => (hour - (layer.first + length / 2)) / length
    anchors(layer.stack, bands.length, Math.ceil(knot(from)), Math.floor(knot(to)), anchorKnots, anchorMost)
    namesFor = layer.count
  }

  const placeEl = (el: HTMLElement, at: [number, number], x: number, y: number) => {
    const px = Math.round(x)
    const py = Math.round(y)
    if (at[0] === px && at[1] === py) return
    el.style.transform = `translate3d(${px}px, ${py}px, 0)`
    at[0] = px
    at[1] = py
  }

  function placeNames() {
    const layer = layers[front]
    if (layer.level < 0 || layer.n < 2) {
      for (const el of nameEls) el.hidden = true
      return
    }
    if (namesFor !== layer.count) pickAnchors()
    const {hours: length} = LEVELS[layer.level]
    const picked = chosenPlace()
    for (let place = 0; place < bands.length; place++) {
      let el = nameEls[place]
      if (!el) {
        el = names.appendChild(document.createElement("span"))
        el.className = "atlas-river__name"
        nameEls.push(el)
        nameAt.push([NaN, NaN])
      }
      const knot = anchorKnots[place]
      const title = bands[rankAt[place]].title
      if (el.textContent !== title) el.textContent = title
      el.toggleAttribute("data-chosen", place === picked)
      let shown = knot >= 0 && knot < layer.n - 1 && !(place === picked && shape.lanes > 0.5)
      if (shown) {
        bounds(layer.stack, knot, 0, layerShape(layer), bounded)
        bandExtent(layer.stack, place)
        const x = screenX(layer.first + length / 2 + knot * length)
        const y = view.middle - (extent[0] + extent[1]) / 2
        shown = extent[1] - extent[0] >= NAMED && x > 0 && x < width && y > AXIS + 8 && y < height - 8
        if (shown) placeEl(el, nameAt[place], x, y)
      }
      if (el.hidden === shown) el.hidden = !shown
    }
    for (let place = bands.length; place < nameEls.length; place++) if (!nameEls[place].hidden) nameEls[place].hidden = true

    for (let lane = 0; lane < Math.max(kinds.length, laneEls.length); lane++) {
      let el = laneEls[lane]
      if (!el) {
        el = names.appendChild(document.createElement("span"))
        el.className = "atlas-river__lane"
        laneEls.push(el)
        laneAt.push(NaN)
      }
      const name = laneNames.get(kinds[lane]) ?? ""
      const y = Math.round(view.middle - laneTop(lane) + 4)
      const shown = lane < kinds.length && shape.lanes > 0.5 && y > AXIS && y < height - 12
      if (shown) {
        if (el.textContent !== name) el.textContent = name
        if (laneAt[lane] !== y) {
          el.style.transform = `translate3d(0, ${y}px, 0)`
          laneAt[lane] = y
        }
      }
      if (el.hidden === shown) el.hidden = !shown
    }
  }

  // The bottom and top of the band at `place` from the last `bounds`, up from
  // the middle, into `extent`.
  const extent = new Float64Array(2)
  function bandExtent(at: Stack, place: number) {
    let lower = Infinity
    let upper = -Infinity
    for (let s = 0; s < at.series.length; s++) {
      if (at.series[s].band !== place) continue
      lower = Math.min(lower, bounded[2 * s])
      upper = Math.max(upper, bounded[2 * s + 1])
    }
    extent[0] = lower === Infinity ? 0 : lower
    extent[1] = lower === Infinity ? 0 : upper
  }

  const layerShape = (layer: Layer) => {
    shape.ko = layer.ko
    shape.kf = layer.kf
    return shape
  }

  // ——— Cards ———————————————————————————————————————————————————————————————

  // Each card on screen, by its hour's own entry: a thing changed in two hours has a card in each.
  const placed = new Map<Item, HTMLElement>()
  const spots = new Map<HTMLElement, [number, number]>()
  const spare: HTMLElement[] = []
  const seen = new Map<Item, number>()
  const chips = new Map<string, HTMLAnchorElement>()
  const spareChips: HTMLAnchorElement[] = []
  const chipSeen = new Map<string, number>()
  let pass = 0
  let deckShown = -1

  const makeCard = () => {
    const el = document.createElement("div")
    el.className = "atlas-river__card"
    el.innerHTML =
      '<p class="atlas-river__card-top"><span class="atlas-river__card-mark" aria-hidden="true"></span>' +
      '<span class="atlas-river__card-what"></span><span class="atlas-river__card-at"></span></p>' +
      '<a class="atlas-river__card-title"></a>'
    const link = el.querySelector<HTMLAnchorElement>("a")!
    // A drag that starts on a title moves the picture rather than carrying the link off,
    // and the cards are reached from the picture, in reading order, not by Tab alone.
    link.draggable = false
    link.tabIndex = -1
    deck.append(el)
    return el
  }

  const fill = (el: HTMLElement, item: Item) => {
    el.dataset.id = item.id
    el.dataset.source = item.live ? "graph" : "notebook"
    el.querySelector(".atlas-river__card-what")!.textContent = item.who ? `${item.what} · ${item.who}` : item.what
    el.querySelector(".atlas-river__card-at")!.textContent = clockOf(item.at)
    const link = el.querySelector<HTMLAnchorElement>("a")!
    link.textContent = item.title
    link.title = item.title
    link.href = item.path
    if (item.live) {
      link.dataset.phxLink = "patch"
      link.dataset.phxLinkState = "push"
    } else {
      delete link.dataset.phxLink
      delete link.dataset.phxLinkState
    }
  }

  const place = (el: HTMLElement, x: number, y: number) => {
    let spot = spots.get(el)
    if (!spot) {
      spot = [NaN, NaN]
      spots.set(el, spot)
    }
    placeEl(el, spot, x, y)
  }

  function takeCard(item: Item, x: number, y: number) {
    let el = placed.get(item)
    if (!el) {
      el = spare.pop() ?? makeCard()
      el.hidden = false
      fill(el, item)
      placed.set(item, el)
    }
    el.toggleAttribute("data-pinned", item.id === pinned)
    place(el, x, y)
    seen.set(item, pass)
    if (item.id === pinned && focusPinned) {
      focusPinned = false
      el.querySelector<HTMLAnchorElement>("a")!.focus({preventScroll: true})
    }
  }

  function takeChip(key: string, hour: number, more: number, x: number, y: number) {
    let el = chips.get(key)
    if (!el) {
      el = spareChips.pop() ?? deck.appendChild(document.createElement("a"))
      el.className = "atlas-river__more-things"
      el.draggable = false
      el.dataset.phxLink = "patch"
      el.dataset.phxLinkState = "push"
      el.hidden = false
      chips.set(key, el)
    }
    const text = `+${more} more`
    if (el.textContent !== text) el.textContent = text
    const href = listOf(hour)
    if (el.getAttribute("href") !== href) el.setAttribute("href", href)
    place(el, x, y)
    chipSeen.set(key, pass)
  }

  // The List of the day holding `hour`, which has every thing changed in it.
  function listOf(hour: number) {
    const url = new URL(window.location.href)
    url.searchParams.set("show", "list")
    url.searchParams.set("window", "day")
    url.searchParams.set("at", dateOf(hour))
    return url.pathname + url.search
  }

  // A lane's row in one hour: where each card would stand, under its thing's
  // mark, where it does, and its thing.
  const wanted = new Float64Array(ROW)
  const lefts = new Float64Array(ROW)
  const inRow: Item[] = []
  const onScreen = (x: number) => x + CARD_WIDTH > 0 && x < width

  // Each lane's cards in each hour on screen, in the order they happened, as
  // many as the hour holds; with more, the last place goes to a link to the
  // rest, and the chosen thing takes the place before it if it would miss out.
  function placeCards(from: number, to: number) {
    pass += 1
    const shownNow = chosen !== null ? Math.round(view.cards * 50) / 50 : 0
    if (shownNow !== deckShown) {
      deckShown = shownNow
      deck.hidden = shownNow === 0
      deck.style.opacity = String(shownNow)
    }
    if (shownNow > 0) {
      const project = chosen!
      const slots = columns(camera.zoom, CARD_WIDTH, CARD_GAP, CARD_PAD)
      for (let hour = Math.floor(from); hour <= Math.floor(to); hour++) {
        fetchItems(project, hour)
        const key = itemKey(project, hour)
        const start = screenX(hour) + CARD_PAD
        const end = screenX(hour + 1) - CARD_PAD
        for (const [lane, list] of groupOf(key)) {
          const top = view.middle - laneTop(lane) + STRIP
          if (top + CARD_HEIGHT < AXIS + CARD_SEEN || top > height - CARD_SEEN) continue
          const fits = list.length > slots ? slots - 1 : list.length
          let held = -1
          for (let index = fits; index < list.length; index++) if (list[index].id === pinned) held = index
          for (let index = 0; index < fits; index++) {
            const item = held >= 0 && index === fits - 1 ? list[held] : list[index]
            inRow[index] = item
            wanted[index] = screenX(hourOf(item.at)) - CARD_MARK
          }
          const count = fits < list.length ? fits + 1 : fits
          wanted[fits] = end
          row(wanted, count, start, end, CARD_WIDTH, CARD_GAP, lefts)
          for (let index = 0; index < fits; index++) {
            if (onScreen(lefts[index])) takeCard(inRow[index], lefts[index], top)
          }
          if (count > fits && onScreen(lefts[fits])) {
            takeChip(`${key}:${lane}`, hour, list.length - fits, lefts[fits], top)
          }
        }
      }
    }
    for (const [item, el] of placed) {
      if (seen.get(item) === pass) continue
      // A card in focus stays until focus leaves it.
      if (el.contains(document.activeElement)) continue
      el.hidden = true
      placed.delete(item)
      seen.delete(item)
      spare.push(el)
    }
    for (const [key, el] of chips) {
      if (chipSeen.get(key) === pass) continue
      el.hidden = true
      chips.delete(key)
      chipSeen.delete(key)
      spareChips.push(el)
    }
  }

  // ——— The times along the top ——————————————————————————————————————————————

  const context = document.createElement("span")
  context.className = "atlas-river__context"
  axis.append(context)
  let contextText = ""
  let contextWidth = 0
  let contextPush = 0
  const ticks: HTMLElement[] = []
  const tickAt: number[] = []
  const tickHeld: boolean[] = []
  let tickCount = 0
  let tickZoom = 1
  // Where marks may stand, right of the name at the left edge, and the words
  // of the last mark gone under it.
  let tickEdge = 0
  let held: string | undefined

  const mark = (x: number, text: string, hold: boolean) => {
    let el = ticks[tickCount]
    if (!el) {
      el = axis.appendChild(document.createElement("span"))
      el.className = "atlas-river__tick"
      ticks.push(el)
      tickAt.push(NaN)
      tickHeld.push(false)
    }
    if (el.hidden) el.hidden = false
    if (el.textContent !== text) el.textContent = text
    if (tickHeld[tickCount] !== hold) {
      el.classList.toggle("atlas-river__tick--held", hold)
      tickHeld[tickCount] = hold
    }
    if (tickAt[tickCount] !== x) {
      el.style.transform = `translate3d(${x}px, 0, 0)`
      tickAt[tickCount] = x
    }
    tickCount += 1
  }

  // A mark gone under the name stays beside it while its stretch has room on
  // screen, so the hour looked into is always named.
  const hold = (until: number) => {
    if (held !== undefined && until - tickEdge >= HELD_ROOM) mark(tickEdge, held, true)
    held = undefined
  }

  const tick = (hour: number, text: string) => {
    const x = Math.round((hour - camera.x) * tickZoom + width / 2)
    if (x < tickEdge) {
      held = text
      return
    }
    if (x > width - 8) return
    hold(x)
    mark(x, text, false)
  }

  function placeAxis(lvl: number, from: number, to: number) {
    const text = contextOf(lvl, from)
    if (text !== contextText) {
      contextText = text
      context.textContent = text
      contextWidth = context.offsetWidth
    }
    // The next year, month or day pushes the name of the one at the left edge
    // out of its way as it comes in, so its own first mark is never hidden.
    const push = Math.min(0, Math.round(screenX(nextContext(lvl, from))) - contextWidth - 12)
    if (push !== contextPush) {
      contextPush = push
      context.style.transform = push ? `translate3d(${push}px, 0, 0)` : ""
    }
    tickEdge = contextWidth + push + 12
    tickCount = 0
    tickZoom = camera.zoom
    held = undefined
    eachTick(lvl, from, to, tickZoom, tick)
    hold(width)
    for (let index = tickCount; index < ticks.length; index++) if (!ticks[index].hidden) ticks[index].hidden = true
  }

  // ——— Each frame ———————————————————————————————————————————————————————————

  // How far the lanes, the marks and the cards have come in at this zoom.
  function layout(zoom: number) {
    const rank = chosenRank()
    const lanesOn = rank >= 0 && kinds.length > 0 ? ramp(zoom, LANES_FROM, LANES_IN) * open.value : 0
    shape.open = open.value
    shape.lanes = lanesOn
    view.open = open.value
    view.lanes = lanesOn
    view.marks = lanesOn >= 0.999 ? ramp(zoom, MARKS_FROM, MARKS_IN) : 0
    view.cards = view.marks >= 0.999 ? ramp(zoom, CARDS_FROM, CARDS_IN) : 0
    streamTop = AXIS + PAD
    streamHeight = Math.max(48, height - AXIS - 2 * PAD)
    const centre = streamTop + streamHeight / 2
    const lanes = Math.max(1, kinds.length)
    const fit = Math.max(LANE, (SHARE * streamHeight) / lanes)
    const lane = view.lane
    const region = view.region
    view.lane = fit + (LANE_CARDS - fit) * view.cards
    view.region = lanes * view.lane
    view.line = view.lane / 2 + (STRIP / 2 - view.lane / 2) * view.cards
    view.spread = Math.max(0, view.lane - 18)
    view.laneScale = ((view.lane - 10) * (1 - view.cards) + (STRIP - 8) * view.cards) / Math.max(1, laneMost)
    shape.region = view.region

    // Lanes taller than the picture move up and down; as they grow, the point
    // of them under the pointer, or in the middle, stays where it is.
    if (lanesOn >= 0.999 && lane !== view.lane) {
      const y = pointerY >= 0 ? pointerY : centre
      const down = (region / 2 - (view.middle - y)) / lane
      shift = y - centre + view.region / 2 - down * view.lane
    }
    // The rest of the stream keeps what the chosen band leaves of the height.
    const overflow = Math.max(0, view.region * lanesOn + (1 - SHARE) * streamHeight * open.value - streamHeight) / 2
    shift = clamp(shift, -overflow, overflow)
    view.middle = centre + shift
  }

  // The scales a layer is drawn at, from the busiest bucket of its level.
  function scaleLayer(layer: Layer) {
    const counts = most[Math.max(0, layer.level)]
    scales(streamHeight, SHARE, counts.total, counts.chosen, counts.others, open.value, layer)
  }

  // Zooming in past where lanes begin gives the band under the pointer, or in
  // the middle, the height, as soon as there is one there; zooming back out
  // lets a band so chosen go again.
  const zoomed: Spot = {place: -1, lane: -1, mark: -1, at: 0}
  function zoomChooses(zoom: number, before: number) {
    if (before < LANES_FROM && zoom >= LANES_FROM) zoomOpens = chosen === null
    else if (zoom < LANES_FROM) zoomOpens = false
    if (zoomOpens) {
      const x = pointerX >= 0 ? pointerX : width / 2
      const y = pointerY >= 0 ? pointerY : streamTop + streamHeight / 2
      if (bandAt(x, y, zoomed) && bands[rankAt[zoomed.place]].project !== null) {
        choose(rankAt[zoomed.place], true, !instant())
      }
    } else if (zoom < LANES_CLOSE && chosenByZoom && chosen !== null && !opening) {
      choose(-1, false, !instant())
    }
  }

  function paint() {
    const renderer = island?.renderer()
    if (!renderer) return
    const layer = layers[front]
    const back = layers[1 - front]
    view.hour = camera.x
    view.zoom = camera.zoom
    view.chosen = chosenPlace()
    const spot = ringed()
    view.hoverBand = spot && spot.mark < 0 && spot.lane < 0 ? spot.place : -1
    view.hoverLane = spot && spot.mark < 0 ? spot.lane : -1
    view.hoverMark = spot ? spot.mark : -1
    renderer.layer(front, layer.base, LEVELS[Math.max(0, layer.level)].hours, fade.value, layer.ko, layer.kf)
    renderer.layer(1 - front, back.base, LEVELS[Math.max(0, back.level)].hours, 1 - fade.value, back.ko, back.kf)
    renderer.bases(lanesBuilt.base, marksBuilt.base, layer.kf)
    renderer.view(view)
    island!.nudge()
  }

  let levelWord = ""
  let ringShown = false

  function render() {
    if (!width || !height) return
    const zoom = camera.zoom
    if (camera.y !== 0) {
      if (zoom === lastZoom) shift -= camera.y * zoom
      camera.y = 0
    }
    const before = lastZoom
    lastZoom = zoom
    const now = hourOf(Date.now())
    camera.x = clamp(camera.x, now - BEHIND, now + AHEAD)
    zoomChooses(zoom, before)
    layout(zoom)

    const lvl = levelAt(zoom)
    if (lvl !== layers[front].level) switchLevel(lvl)
    const from = camera.x - width / 2 / zoom
    const to = camera.x + width / 2 / zoom
    const across = to - from
    fetchTiles(lvl, from - across, to + across)
    for (const layer of layers) if (layer.level >= 0) scaleLayer(layer)
    const layer = layers[front]
    if (layer.dirty || from < layer.from || to > layer.to) build(front)
    if (waiting && loaded(lvl, from, to)) fadeIn()

    const project = chosen
    if (project !== null && lvl === 2) {
      fetchLanes(project, from - across, to + across)
      if (lanesBuilt.dirty || from < lanesBuilt.from || to > lanesBuilt.to) buildLanes(project, from, to)
      if (zoom >= MARKS_FROM * 0.8 && shape.lanes >= 0.999) {
        for (let hour = Math.floor(from); hour <= Math.floor(to); hour++) fetchItems(project, hour)
        if (marksBuilt.dirty || from < marksBuilt.from || to > marksBuilt.to) buildMarks(project, from, to)
      }
    }
    if (shape.lanes === 0) view.marks = 0
    if (revealKind !== undefined && laneOf.has(revealKind) && shape.lanes >= 0.999) {
      shift = laneTop(laneOf.get(revealKind)!) - view.lane / 2
      revealKind = undefined
      layout(zoom)
    }

    placeAxis(lvl, from, to)
    placeNames()
    placeCards(from, to)
    placeRing()
    const word =
      view.marks >= 0.5 ? "Items" : shape.lanes >= 0.5 ? "Kinds" : LEVELS[lvl].word
    if (word !== levelWord) level.value = levelWord = word

    paint()
    settleLater()
  }

  // ——— Pointing ————————————————————————————————————————————————————————————

  const local = (clientX: number, clientY: number) => {
    const box = surface.getBoundingClientRect()
    return [clientX - box.left - surface.clientLeft, clientY - box.top - surface.clientTop] as const
  }

  // The band at a point of the surface, and the bucket of the level shown there.
  function bandAt(x: number, y: number, into: Spot) {
    const layer = layers[front]
    if (y < AXIS || layer.level < 0 || layer.n < 2) return false
    const {hours: length} = LEVELS[layer.level]
    const hour = camera.x + (x - width / 2) / camera.zoom
    const knot = (hour - (layer.first + length / 2)) / length
    const index = Math.floor(knot)
    if (index < 0 || index >= layer.n - 1) return false
    bounds(layer.stack, index, knot - index, layerShape(layer), bounded)
    const up = view.middle - y
    for (let s = 0; s < layer.stack.series.length; s++) {
      if (bounded[2 * s] <= up && up <= bounded[2 * s + 1]) {
        into.place = layer.stack.series[s].band
        into.lane = -1
        into.mark = -1
        into.at = bucketOf(hour, length)
        return true
      }
    }
    return false
  }

  // What is at a point of the surface: a thing's mark, a lane, or a band.
  function spotAt(x: number, y: number, into: Spot) {
    if (y < AXIS) return false
    const hour = camera.x + (x - width / 2) / camera.zoom
    if (view.marks > 0.3) {
      let best = -1
      let nearest = Infinity
      for (let index = 0; index < marked.length; index++) {
        const item = marked[index]
        const lane = laneOf.get(item.kind)!
        const dx = screenX(hourOf(item.at)) - x
        const dy = view.middle - (lineOf(lane) + item.spread * view.spread * (1 - view.cards)) - y
        const reach = (7 + 2 * Math.sqrt(Math.min(item.changes, 16))) / 2 + 3
        const distance = dx * dx + dy * dy
        if (distance <= reach * reach && distance < nearest) {
          best = index
          nearest = distance
        }
      }
      if (best >= 0) {
        into.mark = best
        into.lane = laneOf.get(marked[best].kind)!
        into.place = chosenPlace()
        into.at = bucketOf(hour, 1)
        return true
      }
    }
    if (shape.lanes > 0.5) {
      const lane = Math.floor((view.region / 2 - (view.middle - y)) / view.lane)
      if (lane >= 0 && lane < kinds.length) {
        into.lane = lane
        into.mark = -1
        into.place = chosenPlace()
        into.at = bucketOf(hour, 1)
        return true
      }
    }
    return bandAt(x, y, into)
  }

  const tapped: Spot = {place: -1, lane: -1, mark: -1, at: 0}

  function tap(clientX: number, clientY: number, target: EventTarget | null) {
    if (target instanceof Element && target.closest("a, button")) return
    const [x, y] = local(clientX, clientY)
    if (!spotAt(x, y, tapped)) {
      if (chosen !== null && shape.lanes < 0.5) choose(-1, false, !instant())
      return
    }
    lookInto(tapped, !instant())
  }

  // Looks closer at a spot: gives its band the height, opens the rest, or
  // moves to the next level, the lanes, the marks, the cards, and a thing's card.
  function lookInto(spot: Spot, glide: boolean) {
    cursor.place = spot.place
    cursor.lane = Math.max(0, spot.lane)
    cursor.at = spot.at
    if (spot.mark >= 0) {
      const item = marked[spot.mark]
      pinned = item.id
      marksBuilt.dirty = true
      const zoom = Math.max(camera.zoom, LOOK)
      go(hourOf(item.at) + (CARD_WIDTH / 2 - CARD_MARK) / zoom, zoom, glide)
      return
    }
    const rank = rankAt[spot.place]
    if (spot.lane < 0) {
      if (bands[rank].project === null) {
        restOpen = !restOpen
        arrange()
        render()
        return
      }
      if (rank !== chosenRank() || open.value < 0.5) {
        choose(rank, false, glide)
        return
      }
    }
    const zoom = camera.zoom
    const length = LEVELS[levelNow()].hours
    const closer =
      zoom < DAYS_FROM
        ? Math.max(DAYS_FROM * 1.1, width / (168 * 1.15))
        : zoom < HOURS_FROM
          ? Math.max(HOURS_FROM * 1.1, width / (24 * 1.15))
          : zoom < LANES_IN
            ? Math.max(LANES_IN * 1.05, width / 16)
            : zoom < MARKS_IN
              ? Math.max(MARKS_IN * 1.05, width / 6)
              : zoom < CARDS_IN
                ? LOOK
                : zoom
    if (closer !== zoom) go(spot.at + length / 2, closer, glide)
  }

  // ——— Words ———————————————————————————————————————————————————————————————

  function words(spot: Spot) {
    const lvl = levelNow()
    if (spot.mark >= 0) {
      const item = marked[spot.mark]
      return {
        title: item.title,
        when: [item.what, item.who, clockOf(item.at)].filter(Boolean).join(" · "),
        counts: counted(item.changes, "change", "changes"),
      }
    }
    if (spot.lane >= 0 && chosen !== null) {
      const name = kinds[spot.lane]
      let [changes, things, actors] = [0, 0, 0]
      const cells = laneTiles.get(laneKey(chosen, Math.floor(spot.at / LEVELS[2].tile)))
      for (const cell of cells?.get(spot.at) ?? []) {
        if (cell.kind !== name) continue
        ;[changes, things, actors] = [cell.changes, cell.things, cell.actors]
      }
      return {
        title: laneNames.get(name) ?? name,
        when: bucketLabel("hour", spot.at),
        counts:
          changes === 0
            ? "Nothing changed"
            : [counted(changes, "change", "changes"), counted(things, "thing", "things"), counted(actors, "Key", "Keys")].join(" · "),
      }
    }
    const counts = countsAt(spot.place, spot.at, lvl)
    const title = bands[rankAt[spot.place]]?.title ?? ""
    const when = bucketLabel(LEVELS[lvl].span, spot.at)
    if (!counts) return {title, when, counts: ""}
    if (counts.changes === 0) return {title, when, counts: "Nothing changed"}
    const parts = [counted(counts.changes, "change", "changes"), counted(counts.things, "thing", "things")]
    if (!counts.together) parts.push(counted(counts.actors, "Key", "Keys"))
    if (kind === "all" && counts.notebooks > 0) parts.push(`${counts.notebooks.toLocaleString("en")} in notebooks`)
    return {title, when, counts: parts.join(" · ")}
  }

  const tipTitle = tip.appendChild(document.createElement("strong"))
  const tipWhen = tip.appendChild(document.createElement("span"))
  const tipCounts = tip.appendChild(document.createElement("span"))

  function showTip(x: number, y: number) {
    const said = words(hover)
    tipTitle.textContent = said.title
    tipWhen.textContent = said.when
    tipCounts.textContent = said.counts
    tip.hidden = false
    const [w, h] = [tip.offsetWidth, tip.offsetHeight]
    const left = x + 14 + w > width ? x - 14 - w : x + 14
    const top = clamp(y + 14, AXIS, Math.max(AXIS, height - h - 4))
    tip.style.transform = `translate3d(${Math.round(left)}px, ${Math.round(top)}px, 0)`
  }

  const hideTip = () => {
    if (!tip.hidden) tip.hidden = true
    if (hovering) {
      hovering = false
      paint()
    }
  }

  const say = (spot: Spot) => {
    const {title, when, counts} = words(spot)
    said.textContent = counts ? `${title}, ${when}: ${counts}` : `${title}, ${when}`
  }

  // The spot the ring is on: the one under the pointer, or the keyboard's.
  const ringed = () => (hovering ? hover : keyed && document.activeElement === stage ? spotOfCursor() : undefined)

  const hideRing = () => {
    if (!ringShown) return
    ring.hidden = true
    ringShown = false
  }

  // The keyboard's ring around its bucket of a band, or of a lane, as much of
  // it as is on screen.
  function placeRing() {
    if (!keyed || document.activeElement !== stage) return hideRing()
    const layer = layers[front]
    const length = shape.lanes > 0.5 ? 1 : LEVELS[Math.max(0, layer.level)].hours
    const left = Math.max(1, screenX(cursor.at))
    const right = Math.min(width - 1, screenX(cursor.at + length))
    let lower = 0
    let upper = 0
    if (shape.lanes > 0.5) {
      lower = laneTop(cursor.lane) - view.lane
      upper = laneTop(cursor.lane)
    } else {
      const knot = Math.round((cursor.at - layer.first) / LEVELS[Math.max(0, layer.level)].hours)
      if (knot >= 0 && knot < layer.n - 1) {
        bounds(layer.stack, knot, 0, layerShape(layer), bounded)
        bandExtent(layer.stack, cursor.place)
        lower = extent[0]
        upper = extent[1]
      }
    }
    const top = Math.max(AXIS, view.middle - upper - 3)
    const bottom = Math.min(height - 1, view.middle - lower + 3)
    if (bottom - top < 4 || right - left < 4) return hideRing()
    ring.hidden = false
    ringShown = true
    ring.style.transform = `translate3d(${Math.round(left)}px, ${Math.round(top)}px, 0)`
    ring.style.width = `${Math.round(right - left)}px`
    ring.style.height = `${Math.round(bottom - top)}px`
  }

  // Brings the keyboard's spot into view, at once.
  function reveal() {
    const length = shape.lanes > 0.5 ? 1 : LEVELS[levelNow()].hours
    const middle = cursor.at + length / 2
    const x = screenX(middle)
    if (x < 24 || x > width - 24) camera.jumpTo(middle, 0)
    if (shape.lanes > 0.5) {
      const top = view.middle - laneTop(cursor.lane)
      if (top < AXIS) shift += AXIS - top + 8
      else if (top + view.lane > height) shift -= top + view.lane - height + 8
    }
    render()
  }

  // ——— Listening ———————————————————————————————————————————————————————————

  function keydown(event: KeyboardEvent) {
    if (event.altKey || event.ctrlKey || event.metaKey) return
    const card = event.target instanceof Element ? event.target.closest<HTMLElement>(".atlas-river__card") : null
    if (card) return cardKey(event, card)
    if (event.target !== stage) return
    keyed = true
    stop()
    const inLanes = shape.lanes > 0.5
    const length = inLanes ? 1 : LEVELS[levelNow()].hours
    cursor.at = bucketOf(cursor.at, length)
    const moves: Record<string, [number, number]> = {
      ArrowLeft: [-1, 0],
      ArrowRight: [1, 0],
      ArrowUp: [0, 1],
      ArrowDown: [0, -1],
    }
    const move = moves[event.key]
    if (move) {
      event.preventDefault()
      // The keys walk from as far back as the river goes up to now.
      const now = hourOf(Date.now())
      cursor.at = clamp(cursor.at + move[0] * length, bucketOf(now - BEHIND, length), bucketOf(now, length))
      if (inLanes) cursor.lane = clamp(cursor.lane - move[1], 0, Math.max(0, kinds.length - 1))
      else cursor.place = clamp(cursor.place + move[1], 0, Math.max(0, bands.length - 1))
      cursor.mark = -1
      reveal()
      say(spotOfCursor())
    } else if (event.key === "+" || event.key === "=" || event.key === "-" || event.key === "_") {
      event.preventDefault()
      const factor = event.key === "+" || event.key === "=" ? STEP : 1 / STEP
      const box = surface.getBoundingClientRect()
      camera.zoomBy(factor, box.left + screenX(cursor.at + length / 2), box.top + view.middle)
      cursor.at = bucketOf(cursor.at, shape.lanes > 0.5 ? 1 : LEVELS[levelNow()].hours)
      say(spotOfCursor())
    } else if (event.key === "Enter") {
      event.preventDefault()
      // In the cards, the first of the lane's hour on screen takes focus, or
      // the first of all is brought in to take it.
      if (view.cards >= 0.5 && chosen !== null) {
        const list = groupOf(itemKey(chosen, bucketOf(cursor.at, 1))).get(cursor.lane) ?? []
        const shown = list.find(item => placed.has(item))
        if (shown) placed.get(shown)!.querySelector<HTMLAnchorElement>("a")!.focus({preventScroll: true})
        else if (list.length) bringIn(list[0].id, list[0].at, list[0].kind, true, false)
        else say(spotOfCursor())
        return
      }
      lookInto(spotOfCursor(), false)
      cursor.at = bucketOf(cursor.at, shape.lanes > 0.5 ? 1 : LEVELS[levelNow()].hours)
      say(spotOfCursor())
    } else if (event.key === "Escape") {
      if (chosen !== null) {
        taken(event)
        cursor.place = chosenPlace()
        choose(-1, false, false)
        say(spotOfCursor())
      } else if (restOpen) {
        taken(event)
        restOpen = false
        arrange()
        render()
      }
    }
  }

  // An Escape the river takes closes nothing else on the page.
  const taken = (event: KeyboardEvent) => {
    event.preventDefault()
    event.stopPropagation()
  }

  const keySpot: Spot = {place: 0, lane: -1, mark: -1, at: 0}
  const spotOfCursor = () => {
    keySpot.place = shape.lanes > 0.5 ? chosenPlace() : cursor.place
    keySpot.lane = shape.lanes > 0.5 ? cursor.lane : -1
    keySpot.mark = -1
    keySpot.at = cursor.at
    return keySpot
  }

  // Tab and Shift+Tab step through the cards on screen in reading order and
  // leave at either end; Escape goes back to the picture.
  function cardKey(event: KeyboardEvent, card: HTMLElement) {
    if (event.key === "Escape") {
      taken(event)
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
    next.querySelector<HTMLAnchorElement>("a")!.focus({preventScroll: true})
  }

  function pointermove(event: PointerEvent) {
    const [x, y] = local(event.clientX, event.clientY)
    pointerX = x
    pointerY = y
    if (event.pointerType === "touch" || surface.hasAttribute("data-dragging")) return hideTip()
    if (event.target instanceof Element && event.target.closest(".atlas-river__card, .atlas-river__more-things")) {
      return hideTip()
    }
    if (!spotAt(x, y, hover)) return hideTip()
    hovering = true
    showTip(x, y)
    paint()
  }

  function clicked(event: MouseEvent) {
    const target = event.target instanceof Element ? event.target : null
    const zoom = target?.closest<HTMLElement>("[data-atlas-zoom]")
    if (zoom) {
      const factor = zoom.dataset.atlasZoom === "in" ? STEP : 1 / STEP
      pointerX = -1
      pointerY = -1
      go(camera.x, camera.zoom * factor, byPointer(event) && !still(root))
      return
    }
    if (target?.closest("[data-atlas-more]")) {
      restOpen = !restOpen
      arrange()
      render()
    }
  }

  // Shift and the wheel give the band under the pointer the height, or take it back.
  function wheel(event: WheelEvent) {
    const [x, y] = local(event.clientX, event.clientY)
    pointerX = x
    pointerY = y
    stop()
    hideTip()
    if (!event.shiftKey) return
    event.preventDefault()
    event.stopImmediatePropagation()
    const delta = (event.deltaY || event.deltaX) * (event.deltaMode === WheelEvent.DOM_DELTA_LINE ? 16 : 1)
    if (chosen === null) {
      const spot = {place: -1, lane: -1, mark: -1, at: 0}
      if (delta > 0 || !bandAt(x, y, spot) || bands[rankAt[spot.place]].project === null) return
      choose(rankAt[spot.place], false, false)
      open.value = 0
    }
    opening?.pause()
    opening = undefined
    open.value = clamp(open.value - delta * 0.004, 0, 1)
    if (open.value === 0) choose(-1, false, false)
    else render()
  }

  // A thing chosen in the strip beside the picture: its band given the
  // height, and its card first in its hour and its lane, in the middle.
  function focusThing(event: Event) {
    const {id, project, at, kind: thingKind} = (
      event as CustomEvent<{id: string; project: string; at: number; kind: string}>
    ).detail
    if (rankOf.get(project) === bands.length - 1 && bands[bands.length - 1]?.project === null) {
      restOpen = true
      arrange()
    }
    const rank = rankOf.get(project)
    if (rank !== undefined && bands[rank]?.project === project) choose(rank, false, !instant())
    bringIn(id, at, thingKind, !lastInputByPointer(), !instant())
  }

  // A thing's card first in its hour and its lane, in the middle, and in
  // focus once it stands there when `focus`.
  function bringIn(id: string, at: number, kind: string, focus: boolean, glide: boolean) {
    pinned = id
    focusPinned = focus
    revealKind = kind
    marksBuilt.dirty = true
    cursor.at = bucketOf(hourOf(at), 1)
    const zoom = Math.max(camera.zoom, LOOK)
    go(hourOf(at) + (CARD_WIDTH / 2 - CARD_MARK) / zoom, zoom, glide)
  }

  // ——— Moving ——————————————————————————————————————————————————————————————

  function stop() {
    moving?.pause()
    moving = undefined
  }

  // Moves to an hour and a zoom, gliding in under 300 ms or at once: the zoom
  // eases by its ratio, and the hour moves across the screen as evenly as the
  // zoom allows.
  function go(x: number, zoom: number, glide: boolean) {
    stop()
    const target = clamp(zoom, ZOOM.min, ZOOM.max)
    if (!glide || still(root)) {
      camera.jumpTo(x, 0, target)
      render()
      return
    }
    const [fromX, fromZoom] = [camera.x, camera.zoom]
    const offset = (x - fromX) * fromZoom
    const ratio = Math.log(target / fromZoom)
    const state = {t: 0}
    moving = animate(state, {
      t: 1,
      duration: SLOW,
      ease: EASE_OUT,
      onUpdate: () => {
        const at = fromZoom * Math.exp(ratio * state.t)
        camera.jumpTo(x - (offset * (1 - state.t)) / at, 0, at)
      },
      onComplete: () => {
        moving = undefined
      },
    })
  }

  const interrupt = () => stop()

  stage.addEventListener("keydown", keydown, listen)
  root.addEventListener("click", clicked, listen)
  root.addEventListener("atlas:focus", focusThing, listen)
  surface.addEventListener("pointermove", pointermove, listen)
  surface.addEventListener("pointerleave", () => {
    pointerX = -1
    pointerY = -1
    hideTip()
  }, listen)
  surface.addEventListener(
    "pointerdown",
    () => {
      keyed = false
      interrupt()
    },
    {...listen, capture: true},
  )
  // Heard before the camera's own, so Shift and the wheel never zoom through time.
  surface.addEventListener("wheel", wheel, {...listen, passive: false, capture: true})
  stage.addEventListener("focus", () => render(), listen)
  stage.addEventListener("blur", () => render(), listen)

  // ——— The window in the address ——————————————————————————————————————————

  // Frames the window of `name` holding `hour`, across the screen.
  function frame(name: Window, hour: number, glide: boolean) {
    const [start, end] = windowOf(name, hour)
    go((start + end) / 2, width / ((end - start) * 1.04), glide)
  }

  function settleLater() {
    movedAt = performance.now()
    if (!settleTimer) settleTimer = window.setTimeout(settle, SETTLE)
  }

  // Once the view rests, the names stand where their bands are thickest, and
  // the window in view is named in the address, unless it already is.
  function settle() {
    settleTimer = 0
    const idle = performance.now() - movedAt
    if (idle < SETTLE) {
      settleTimer = window.setTimeout(settle, SETTLE - idle)
      return
    }
    if (moving) return
    placeNamesFor()
    placeNames()
    if (!named) return
    const name = windowFor(width / camera.zoom)
    const [start, end] = windowOf(name, camera.x)
    if (named.window === name && named.start === start) return
    if (asked?.window === name && asked.start === start) return
    asked = {window: name, start}
    // The day the address names: today while the window holds it, else the middle of the view.
    const today = hourOf(Date.now())
    const at = today >= start && today < end ? today : camera.x
    ask("atlas_window", {span: name, at: Math.floor(msOf(at) / 1000)})
  }

  function readWindow(glide: boolean) {
    const name = (root.dataset.window ?? "year") as Window
    const hour = hourOf(Number(root.dataset.at))
    const [start] = windowOf(name, hour)
    if (named?.window === name && named.start === start) return
    named = {window: name, start}
    // The address now names what the picture asked for, or what is in view.
    if (asked?.window === name && asked.start === start) return
    if (width && windowFor(width / camera.zoom) === name && windowOf(name, camera.x)[0] === start) return
    if (width) {
      cursor.at = bucketOf(hour, LEVELS[levelAt(width / (windowOf(name, hour)[1] - start))].hours)
      frame(name, hour, glide)
    }
  }

  // ——— The page ————————————————————————————————————————————————————————————

  function forget() {
    generation += 1
    for (const lvl of [0, 1, 2]) {
      tiles[lvl].clear()
      asking[lvl].clear()
      stale[lvl].clear()
      most[lvl].total = most[lvl].chosen = most[lvl].others = 0
    }
    laneTiles.clear()
    askingLanes.clear()
    staleLanes.clear()
    items.clear()
    askingItems.clear()
    staleItems.clear()
    grouped.clear()
    kinds = []
    laneOf = new Map()
    laneMost = 0
    for (const layer of layers) layer.dirty = true
    lanesBuilt.dirty = true
    marksBuilt.dirty = true
  }

  function update() {
    const nextKind = root.dataset.kind ?? "all"
    if (nextKind !== kind) {
      if (kind) {
        forget()
        rows = []
        rowsJson = ""
      }
      kind = nextKind
    }
    if (readRows()) arrange()
    readWindow(!instant())
    render()
  }

  function changed() {
    for (const lvl of [0, 1, 2]) for (const index of tiles[lvl].keys()) stale[lvl].add(index)
    for (const key of laneTiles.keys()) staleLanes.add(key)
    for (const key of items.keys()) staleItems.add(key)
    for (const lvl of [0, 1, 2]) asking[lvl].clear()
    askingLanes.clear()
    askingItems.clear()
    render()
  }

  let framed = false
  const resize = new ResizeObserver(() => {
    width = surface.clientWidth
    height = surface.clientHeight
    if (!framed && width && height && named) {
      framed = true
      const [start, end] = windowOf(named.window, hourOf(Number(root.dataset.at)))
      cursor.at = bucketOf(hourOf(Number(root.dataset.at)), LEVELS[levelAt(width / (end - start))].hours)
      camera.jumpTo((start + end) / 2, 0, width / ((end - start) * 1.04))
    }
    placeNamesFor()
    render()
  })
  resize.observe(surface)

  if (!navigator.gpu) surface.dataset.atlasStill = "true"
  const controller = createCanvasIsland<RiverRenderer>(surface, {}, {
    canvasSelector: "[data-atlas-canvas]",
    readyFlag: "atlasReady",
    // The picture is the page's content, so it is drawn for every reader.
    motionSensitive: false,
    continuous: false,
    browserLoad: async (canvas, size, lost) => {
      const {createRiverRenderer} = await import("./renderer")
      return createRiverRenderer(canvas, size, lost)
    },
    interact: ({renderer, nudge, onReady}) => {
      island = {renderer, nudge}
      const retone = () => {
        renderer()?.tones(
          tone(surface, "--atlas-river-1"),
          tone(surface, "--atlas-river-2"),
          tone(surface, "--atlas-river-rest"),
          tone(surface, "--atlas-river-pick"),
          tone(surface, "--palette-cornflower"),
          tone(surface, "--atlas-river-pick"),
          tone(surface, "--color-bg"),
          tone(surface, "--color-focus"),
        )
        nudge()
      }
      onReady(() => {
        retone()
        layers.forEach((layer, slot) => renderer()?.pieces(slot, data[slot], layer.count))
        renderer()?.lanes(laneData, lanesBuilt.count)
        renderer()?.marks(markData, marksBuilt.count)
        paint()
      })
      const forgetTheme = watchTheme(retone)
      return () => {
        forgetTheme()
        island = undefined
        // The GPU is not going to draw: the page says so, and the List has it all.
        surface.dataset.atlasStill = "true"
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
      fading?.pause()
      opening?.pause()
      window.clearTimeout(settleTimer)
      events.abort()
      resize.disconnect()
      camera.destroy()
      controller.destroy()
    },
  }
}
