/**
 * The Atlas as heat: time runs left to right and each project is a row,
 * busiest first, the dozen busiest on their own and the rest folded into one
 * row that opens. Each square is a bucket of time, darker or lighter as the
 * work in it, on one scale from a little to the most. Zooming moves from a
 * year of weeks to a month of days, a day of hours, and inside an hour the
 * rows open into cards, one for each thing changed in it, linking to its page.
 *
 * Nothing the fleet ever did reaches the browser at once. The page answers
 * for the buckets near the view a tile at a time (`atlas_cells`), the cards
 * for an hour on screen (`atlas_cards`), and, once the view settles, names
 * the window in view in the address (`atlas_window`), so the window chosen
 * at the top and the strip of the most active things beside the picture
 * follow it. When the fleet's work is counted again the page says so
 * (`changed`), and what is on screen is read again in place.
 *
 * The wheel and a pinch zoom about the pointer; dragging moves through time
 * and up and down the rows. Pressing a square looks closer at it. With the
 * keyboard, the arrow keys move a ring from square to square, plus and minus
 * zoom about it, and Enter looks closer, or, among the cards, moves to the
 * first card; Tab steps through the cards in reading order, Escape leaves
 * them. Choosing a thing in the strip brings the picture to its card.
 *
 * The squares are drawn on the GPU (`./renderer`), two layers of them so a
 * level fades into the next, and only redrawn when something moved. The
 * times along the top, the rows' names and the cards are the page's own,
 * the cards drawn only inside an hour and only those on screen, from a pool.
 * Moves and fades run under 300 ms with anime.js, and at once after a key
 * press or for a reader who asked for less motion.
 */
import {animate, type JSAnimation} from "animejs"

import {createCamera} from "../../camera"
import {createCanvasIsland} from "../../canvas_island"
import {BASE, EASE_OUT, SLOW, byPointer, lastInputByPointer, still} from "../../hooks/motion/shared"
import {watchTheme} from "../../theme"
import {tone} from "../../theme_tone"
import {CELL_FLOATS, MAX_CELLS, type HeatRenderer} from "./renderer"
import {
  EPOCH,
  HOUR,
  HOURS_FROM,
  DAYS_FROM,
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
  windowFor,
  windowOf,
  type Window,
} from "./time"

/** Asks the page, and hears its answer when it gives one. */
export type Ask = <Reply>(event: string, payload: object, reply?: (reply: Reply) => void) => void

export type HeatStage = {
  /** The page drew the picture's element again: its rows, window or kind may have changed. */
  update(): void
  /** The fleet's work was counted again: what is on screen is read again. */
  changed(): void
  pause(): void
  resume(): void
  destroy(): void
}

type Row = {readonly project: string; title: string}
type Cell = {readonly project: string; readonly changes: number; readonly things: number; readonly actors: number}
type Tile = Map<number, Cell[]>
type Card = {
  readonly id: string
  readonly what: string
  readonly project: string
  readonly title: string
  readonly who: string | null
  readonly at: number
  readonly changes: number
  readonly path: string
  readonly live: boolean
}
type Layer = {level: number; base: number; count: number; from: number; to: number; top: number; bottom: number; dirty: boolean}
type Spot = {row: number; at: number}

// The band of times along the top, in CSS pixels.
const AXIS = 32
// A row's height, and an open row's, where an hour holds two lines of cards.
const ROW = 28
const ROW_OPEN = 168
// The zoom, in CSS pixels an hour, at which rows start to open, are open, and
// the zoom an hour is looked into at.
const OPENS_FROM = 180
const OPEN_AT = 360
const LOOK = 480
const ZOOM = {min: 0.02, max: 2400}
// The busiest rows shown on their own before the rest fold into one.
const FOLD = 12
const STEP = 2
// How long the view rests before the window in view is named in the address, in ms.
const SETTLE = 320
// How long an unanswered question waits before it is asked again, in ms.
const RETRY = 15_000
const KEEP_TILES = 80
const KEEP_HOURS = 48
// A card and the room around it, in CSS pixels.
const CARD_WIDTH = 184
const CARD_HEIGHT = 72
const CARD_GAP = 6
const CARD_PAD = 8
// How far past now and back before it the picture may be moved, in hours.
const AHEAD = 7 * 24
const BEHIND = 20 * 8_784

const clamp = (value: number, low: number, high: number) => Math.min(high, Math.max(low, value))

export function createHeatStage(root: HTMLElement, ask: Ask): HeatStage {
  const stage = root.querySelector<HTMLElement>("[data-atlas-stage]")!
  const rowsBox = root.querySelector<HTMLElement>("[data-atlas-rows]")!
  const surface = root.querySelector<HTMLElement>("[data-atlas-surface]")!
  const axis = root.querySelector<HTMLElement>("[data-atlas-axis]")!
  const deck = root.querySelector<HTMLElement>("[data-atlas-cards]")!
  const tip = root.querySelector<HTMLElement>("[data-atlas-tip]")!
  const level = root.querySelector<HTMLOutputElement>("[data-atlas-level]")!
  const said = root.querySelector<HTMLElement>("[data-atlas-said]")!
  const events = new AbortController()
  const listen = {signal: events.signal}

  // What the page drew: the kind of work shown, the rows and the window named in the address.
  let kind = ""
  let rowsJson = ""
  let rows: Row[] = []
  let opened = false
  // The rows on screen, top to bottom: a project, or the row the rest fold into (null).
  let shown: (Row | null)[] = []
  let rowOf = new Map<string, number>()
  let toggle = -1
  let named: {window: Window; start: number} | undefined
  let asked: {window: Window; start: number} | undefined

  // The counts read so far: tiles of buckets, by level and place, and the cards of each hour.
  let generation = 0
  const tiles = new Map<string, Tile>()
  const asking = new Map<string, number>()
  const stale = new Set<string>()
  const most = [0, 0, 0]
  const hours = new Map<number, Card[]>()
  const askingHours = new Map<number, number>()
  const staleHours = new Set<number>()
  // Each hour's cards by the row they stand in, the chosen thing first.
  const grouped = new Map<number, Map<number, Card[]>>()
  let pinned: string | undefined
  let focusPinned = false

  // The view.
  let width = 0
  let height = 0
  let scroll = 0
  let row = ROW
  let lastZoom = 0
  // How far down the rows the zoom keeps still, in CSS pixels, or -1 for the middle.
  let anchor = -1
  let steer: {row: number; from: number; t: number} | undefined
  let moving: JSAnimation | undefined
  let keyed = false
  const cursor: Spot = {row: 0, at: 0}
  const hover: Spot = {row: 0, at: 0}
  let hovering = false

  // Two layers of squares: the level shown in front, and the one fading out behind it.
  const data = [new Float32Array(MAX_CELLS * CELL_FLOATS), new Float32Array(MAX_CELLS * CELL_FLOATS)]
  const layers: Layer[] = [0, 1].map(() => ({level: -1, base: 0, count: 0, from: 0, to: 0, top: 0, bottom: 0, dirty: true}))
  let front = 0
  const fade = {value: 1}
  let fading: JSAnimation | undefined
  let waiting = false

  let island: {renderer(): HeatRenderer | undefined; nudge(): void} | undefined
  let settleTimer = 0
  let movedAt = 0

  const instant = () => still(root) || !lastInputByPointer()
  const openness = (zoom: number) => clamp((zoom - OPENS_FROM) / (OPEN_AT - OPENS_FROM), 0, 1)
  const rowHeight = (zoom: number) => {
    const open = openness(zoom)
    return ROW + (ROW_OPEN - ROW) * open * open * (3 - 2 * open)
  }
  const visibleRows = () => Math.max(1, (height - AXIS) / row)
  const screenX = (hour: number) => (hour - camera.x) * camera.zoom + width / 2
  const rowTop = (index: number) => AXIS + (index - scroll) * row
  const rowFor = (project: string) => rowOf.get(project)
  const levelNow = () => levelAt(camera.zoom)

  const camera = createCamera(surface, {
    onFrame: () => render(),
    onTap: (x, y, target) => tap(x, y, target),
    reducedMotion: () => still(root),
    zoom: ZOOM,
  })

  // ——— Rows ———————————————————————————————————————————————————————————

  const list = document.createElement("ol")
  list.className = "atlas-heat__labels"
  list.setAttribute("aria-label", "Projects")
  rowsBox.append(list)
  const labels = new Map<string, HTMLLIElement>()
  const toggleItem = document.createElement("li")
  toggleItem.className = "atlas-heat__label atlas-heat__label--more"
  toggleItem.innerHTML =
    '<button type="button" class="atlas-heat__more-rows" aria-expanded="false">' +
    '<span data-word></span> <span class="atlas-heat__count" data-count></span></button>'
  const toggleButton = toggleItem.querySelector("button")!

  const label = (entry: Row) => {
    let item = labels.get(entry.project)
    if (!item) {
      item = document.createElement("li")
      item.className = "atlas-heat__label"
      labels.set(entry.project, item)
    }
    if (item.textContent !== entry.title) {
      item.textContent = entry.title
      item.title = entry.title
    }
    return item
  }

  // The rows on screen, from the rows the page counted and whether the rest are open.
  function arrange() {
    const folds = rows.length > FOLD + 1
    const own = folds ? rows.slice(0, FOLD) : rows
    const rest = folds ? rows.slice(FOLD) : []
    toggle = folds ? FOLD : -1
    shown = folds ? [...own, null, ...(opened ? rest : [])] : [...own]
    rowOf = new Map()
    own.forEach((entry, index) => rowOf.set(entry.project, index))
    rest.forEach((entry, index) => rowOf.set(entry.project, opened ? FOLD + 1 + index : FOLD))

    const items = shown.map(entry => (entry ? label(entry) : toggleItem))
    items.forEach((item, index) => {
      if (list.children[index] !== item) list.insertBefore(item, list.children[index] ?? null)
    })
    while (list.children.length > items.length) list.lastElementChild!.remove()
    toggleButton.setAttribute("aria-expanded", String(opened))
    toggleButton.querySelector("[data-word]")!.textContent = opened ? "Fewer" : "More"
    toggleButton.querySelector("[data-count]")!.textContent = opened ? "" : String(rest.length)
    surface.style.setProperty("--atlas-rows", String(Math.max(1, Math.min(shown.length, FOLD + 1))))

    cursor.row = clamp(cursor.row, 0, Math.max(0, shown.length - 1))
    grouped.clear()
    for (const hour of hours.keys()) group(hour)
    rescale()
  }

  function readRows() {
    const json = root.dataset.rows ?? "[]"
    if (json === rowsJson) return false
    rowsJson = json
    const read = (JSON.parse(json) as [string, string, number][]).map(([project, title]) => ({project, title}))
    // New rows join below the ones shown; a row never moves under the reader.
    const known = new Map(rows.map(entry => [entry.project, entry]))
    for (const entry of read) {
      const was = known.get(entry.project)
      if (was) was.title = entry.title
      else rows.push(entry)
    }
    return true
  }

  // ——— Counts ——————————————————————————————————————————————————————————

  const tileKey = (lvl: number, index: number) => `${lvl}:${index}`

  // The heat scale of each level: the most work any one square holds.
  function measure(lvl: number, tile: Tile) {
    let top = most[lvl]
    for (const cells of tile.values()) {
      let rest = 0
      for (const cell of cells) {
        const at = rowFor(cell.project)
        if (at === toggle && toggle >= 0) rest += cell.changes
        else if (at !== undefined) top = Math.max(top, cell.changes)
      }
      top = Math.max(top, rest)
    }
    if (top === most[lvl]) return
    most[lvl] = top
    for (const layer of layers) if (layer.level === lvl) layer.dirty = true
  }

  function rescale() {
    most.fill(0)
    for (const [key, tile] of tiles) measure(Number(key.slice(0, key.indexOf(":"))), tile)
    for (const layer of layers) layer.dirty = true
  }

  function fetchTiles(lvl: number, from: number, to: number) {
    const {span, tile} = LEVELS[lvl]
    const now = performance.now()
    for (let index = Math.floor(from / tile); index <= Math.floor(to / tile); index++) {
      const key = tileKey(lvl, index)
      if (tiles.has(key) && !stale.has(key)) continue
      if (now - (asking.get(key) ?? -Infinity) < RETRY) continue
      asking.set(key, now)
      const asOf = generation
      const start = (EPOCH + index * tile * HOUR) / 1000
      ask<{cells: [number, string, number, number, number][]}>(
        "atlas_cells",
        {span, from: start, to: start + tile * 3600},
        reply => {
          if (asOf !== generation) return
          asking.delete(key)
          stale.delete(key)
          const read: Tile = new Map()
          for (const [at, project, changes, things, actors] of reply.cells) {
            const hour = hourOf(at * 1000)
            const cells = read.get(hour) ?? []
            cells.push({project, changes, things, actors})
            read.set(hour, cells)
          }
          tiles.delete(key)
          tiles.set(key, read)
          if (tiles.size > KEEP_TILES) tiles.delete(tiles.keys().next().value!)
          measure(lvl, read)
          for (const layer of layers) if (layer.level === lvl) layer.dirty = true
          render()
        },
      )
    }
  }

  const loaded = (lvl: number, from: number, to: number) => {
    const {tile} = LEVELS[lvl]
    for (let index = Math.floor(from / tile); index <= Math.floor(to / tile); index++) {
      if (!tiles.has(tileKey(lvl, index))) return false
    }
    return true
  }

  // One square's counts: a project's, or all the folded projects' together.
  function countsAt(spot: Spot, lvl: number) {
    const {tile} = LEVELS[lvl]
    const cells = tiles.get(tileKey(lvl, Math.floor(spot.at / tile)))
    if (!cells) return undefined
    let [changes, things, actors] = [0, 0, 0]
    for (const cell of cells.get(spot.at) ?? []) {
      if (rowFor(cell.project) !== spot.row) continue
      changes += cell.changes
      things += cell.things
      actors = Math.max(actors, cell.actors)
    }
    return {changes, things, actors, together: spot.row === toggle && !opened}
  }

  // ——— Cards ————————————————————————————————————————————————————————————

  function group(hour: number) {
    const byRow = new Map<number, Card[]>()
    for (const card of hours.get(hour) ?? []) {
      const at = rowFor(card.project)
      if (at === undefined) continue
      const cards = byRow.get(at) ?? []
      if (card.id === pinned) cards.unshift(card)
      else cards.push(card)
      byRow.set(at, cards)
    }
    grouped.set(hour, byRow)
  }

  function fetchCards(hour: number) {
    if (hours.has(hour) && !staleHours.has(hour)) return
    const now = performance.now()
    if (now - (askingHours.get(hour) ?? -Infinity) < RETRY) return
    askingHours.set(hour, now)
    const asOf = generation
    ask<{things: Card[]}>("atlas_cards", {at: msOf(hour) / 1000}, reply => {
      if (asOf !== generation) return
      askingHours.delete(hour)
      staleHours.delete(hour)
      hours.delete(hour)
      // Read newest first; laid out in the order they happened.
      hours.set(hour, [...reply.things].reverse())
      if (hours.size > KEEP_HOURS) {
        const oldest = hours.keys().next().value!
        hours.delete(oldest)
        grouped.delete(oldest)
      }
      group(hour)
      render()
    })
  }

  const placed = new Map<string, HTMLElement>()
  const spots = new Map<HTMLElement, [number, number]>()
  const spare: HTMLElement[] = []
  const seen = new Map<string, number>()
  const chips = new Map<number, HTMLAnchorElement>()
  const spareChips: HTMLAnchorElement[] = []
  const chipSeen = new Map<number, number>()
  let pass = 0
  let deckShown = ""

  const makeCard = () => {
    const el = document.createElement("div")
    el.className = "atlas-card"
    el.innerHTML =
      '<p class="atlas-card__top"><span class="atlas-card__mark" aria-hidden="true"></span>' +
      '<span class="atlas-card__what"></span><span class="atlas-card__at"></span></p>' +
      '<a class="atlas-card__title"></a>'
    const link = el.querySelector<HTMLAnchorElement>(".atlas-card__title")!
    // A drag that starts on a title moves the picture rather than carrying the link off,
    // and the cards are reached from the picture, in reading order, not by Tab alone.
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
    const [px, py] = [Math.round(x), Math.round(y)]
    if (spot && spot[0] === px && spot[1] === py) return
    el.style.transform = `translate3d(${px}px, ${py}px, 0)`
    if (spot) {
      spot[0] = px
      spot[1] = py
    } else spots.set(el, [px, py])
  }

  function takeCard(card: Card, x: number, y: number) {
    let el = placed.get(card.id)
    if (!el) {
      el = spare.pop() ?? makeCard()
      el.hidden = false
      fill(el, card)
      placed.set(card.id, el)
    }
    el.toggleAttribute("data-pinned", card.id === pinned)
    place(el, x, y)
    seen.set(card.id, pass)
    if (card.id === pinned && focusPinned) {
      focusPinned = false
      el.querySelector<HTMLAnchorElement>(".atlas-card__title")!.focus({preventScroll: true})
    }
  }

  function takeChip(key: number, hour: number, more: number, x: number, y: number) {
    let el = chips.get(key)
    if (!el) {
      el = spareChips.pop() ?? deck.appendChild(document.createElement("a"))
      el.className = "atlas-heat__more"
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
    url.searchParams.delete("view")
    url.searchParams.set("show", "list")
    url.searchParams.set("window", "day")
    url.searchParams.set("at", dateOf(hour))
    return url.pathname + url.search
  }

  function placeCards(from: number, to: number) {
    pass += 1
    const zoom = camera.zoom
    const open = openness(zoom)
    const strength = clamp((open - 0.4) / 0.6, 0, 1)
    const shownNow = strength > 0 ? strength.toFixed(2) : ""
    if (shownNow !== deckShown) {
      deckShown = shownNow
      deck.hidden = strength === 0
      deck.style.opacity = shownNow
    }
    if (strength > 0) {
      const columns = Math.max(1, Math.floor((zoom - 2 * CARD_PAD + CARD_GAP) / (CARD_WIDTH + CARD_GAP)))
      const lanes = Math.max(1, Math.floor((row - 2 * CARD_PAD + CARD_GAP) / (CARD_HEIGHT + CARD_GAP)))
      const slots = columns * lanes
      const first = Math.max(0, Math.floor(scroll))
      const last = Math.min(shown.length - 1, Math.ceil(scroll + visibleRows()))
      for (let hour = Math.floor(from); hour <= Math.floor(to); hour++) {
        fetchCards(hour)
        const byRow = grouped.get(hour)
        if (!byRow) continue
        const left = screenX(hour) + CARD_PAD
        for (let index = first; index <= last; index++) {
          const cards = byRow.get(index)
          if (!cards) continue
          const top = rowTop(index) + CARD_PAD
          const fits = cards.length > slots ? slots - 1 : cards.length
          for (let slot = 0; slot < fits; slot++) {
            const x = left + (slot % columns) * (CARD_WIDTH + CARD_GAP)
            const y = top + Math.floor(slot / columns) * (CARD_HEIGHT + CARD_GAP)
            takeCard(cards[slot], x, y)
          }
          if (fits < cards.length) {
            const slot = slots - 1
            const x = left + (slot % columns) * (CARD_WIDTH + CARD_GAP)
            const y = top + Math.floor(slot / columns) * (CARD_HEIGHT + CARD_GAP)
            takeChip(hour * 4096 + index, hour, cards.length - fits, x, y)
          }
        }
      }
    }
    for (const [id, el] of placed) {
      if (seen.get(id) === pass) continue
      // A card in focus stays until focus leaves it.
      if (el.contains(document.activeElement)) continue
      el.hidden = true
      placed.delete(id)
      seen.delete(id)
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

  // ——— The times along the top ——————————————————————————————————————————

  const context = document.createElement("span")
  context.className = "atlas-heat__context"
  axis.append(context)
  let contextText = ""
  let contextWidth = 0
  const ticks: HTMLElement[] = []
  const tickAt: number[] = []
  let tickCount = 0
  let tickZoom = 1

  const tick = (hour: number, text: string) => {
    const x = Math.round((hour - camera.x) * tickZoom + width / 2)
    if (x < contextWidth + 12 || x > width - 8) return
    let el = ticks[tickCount]
    if (!el) {
      el = axis.appendChild(document.createElement("span"))
      el.className = "atlas-heat__tick"
      ticks.push(el)
      tickAt.push(NaN)
    }
    if (el.hidden) el.hidden = false
    if (el.textContent !== text) el.textContent = text
    if (tickAt[tickCount] !== x) {
      el.style.transform = `translate3d(${x}px, 0, 0)`
      tickAt[tickCount] = x
    }
    tickCount += 1
  }

  function placeAxis(lvl: number, from: number, to: number) {
    const text = contextOf(lvl, from)
    if (text !== contextText) {
      contextText = text
      context.textContent = text
      contextWidth = context.offsetWidth
    }
    tickCount = 0
    tickZoom = camera.zoom
    eachTick(lvl, from, to, tickZoom, tick)
    for (let index = tickCount; index < ticks.length; index++) if (!ticks[index].hidden) ticks[index].hidden = true
  }

  // ——— Drawing ——————————————————————————————————————————————————————————

  function build(slot: number) {
    const layer = layers[slot]
    const {hours: length, tile} = LEVELS[layer.level]
    const across = width / camera.zoom
    const out = data[slot]
    layer.base = Math.round(camera.x)
    layer.from = camera.x - 1.5 * across
    layer.to = camera.x + 1.5 * across
    layer.top = Math.floor(scroll - visibleRows())
    layer.bottom = Math.ceil(scroll + 2 * visibleRows())
    const scale = Math.log1p(Math.max(1, most[layer.level]))
    let count = 0
    for (let place = Math.floor(layer.from / tile); place <= Math.floor(layer.to / tile); place++) {
      const cells = tiles.get(tileKey(layer.level, place))
      if (!cells) continue
      for (const [at, bucket] of cells) {
        if (at + length < layer.from || at > layer.to) continue
        let rest = 0
        for (const cell of bucket) {
          const index = rowFor(cell.project)
          if (index === undefined) continue
          if (index === toggle && !opened) {
            rest += cell.changes
            continue
          }
          if (index < layer.top || index > layer.bottom || count >= MAX_CELLS) continue
          out[count * 4] = at - layer.base
          out[count * 4 + 1] = length
          out[count * 4 + 2] = index
          out[count * 4 + 3] = Math.log1p(cell.changes) / scale
          count += 1
        }
        if (rest > 0 && toggle >= layer.top && toggle <= layer.bottom && count < MAX_CELLS) {
          out[count * 4] = at - layer.base
          out[count * 4 + 1] = length
          out[count * 4 + 2] = toggle
          out[count * 4 + 3] = Math.log1p(rest) / scale
          count += 1
        }
      }
    }
    layer.count = count
    layer.dirty = false
    island?.renderer()?.cells(slot, out, count)
  }

  // A new level comes in front of the one shown, and fades in once its counts are read.
  function switchLevel(lvl: number) {
    if (fade.value >= 0.5) front = 1 - front
    const layer = layers[front]
    layer.level = lvl
    layer.count = 0
    layer.dirty = true
    island?.renderer()?.cells(front, data[front], 0)
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

  // The square the ring is on: the one under the pointer, or the keyboard's.
  const ringed = () => (hovering ? hover : keyed && document.activeElement === stage ? cursor : undefined)

  function paint() {
    const renderer = island?.renderer()
    if (!renderer) return
    const layer = layers[front]
    renderer.view(camera.x, camera.zoom, AXIS - scroll * row, row, shown.length, opened ? toggle : -1, AXIS)
    renderer.layer(front, layer.base, fade.value)
    renderer.layer(1 - front, layers[1 - front].base, 1 - fade.value)
    renderer.grid(LEVELS[Math.max(0, layer.level)].hours, layer.base)
    const spot = ringed()
    renderer.pick(spot ? front : -1, spot?.at ?? 0, spot?.row ?? 0)
    island!.nudge()
  }

  let levelWord = ""
  let listRow = 0
  let listOffset = NaN

  function render() {
    if (!width || !height) return
    const zoom = camera.zoom
    if (camera.y !== 0) {
      if (zoom === lastZoom) {
        scroll += (camera.y * zoom) / row
        steer = undefined
      }
      camera.y = 0
    }
    const now = hourOf(Date.now())
    camera.x = clamp(camera.x, now - BEHIND, now + AHEAD)

    const next = rowHeight(zoom)
    if (steer) {
      row = next
      const middle = steer.row + 0.5 - visibleRows() / 2
      scroll = steer.from + (middle - steer.from) * steer.t
    } else if (next !== row) {
      const y = anchor >= 0 ? anchor : (height - AXIS) / 2
      const at = scroll + y / row
      row = next
      scroll = at - y / row
    }
    scroll = clamp(scroll, 0, Math.max(0, shown.length - visibleRows()))
    lastZoom = zoom
    if (row !== listRow) {
      listRow = row
      list.style.setProperty("--atlas-row", `${row}px`)
    }
    const offset = Math.round((AXIS - scroll * row) * 2) / 2
    if (offset !== listOffset) {
      listOffset = offset
      list.style.transform = `translate3d(0, ${offset}px, 0)`
    }

    const lvl = levelAt(zoom)
    if (lvl !== layers[front].level) switchLevel(lvl)
    const from = camera.x - width / 2 / zoom
    const to = camera.x + width / 2 / zoom
    const across = to - from
    fetchTiles(lvl, from - across, to + across)
    const layer = layers[front]
    if (
      layer.dirty ||
      from < layer.from ||
      to > layer.to ||
      Math.floor(scroll) < layer.top ||
      Math.ceil(scroll + visibleRows()) > layer.bottom
    ) {
      build(front)
    }
    if (waiting && loaded(lvl, from, to)) fadeIn()

    placeAxis(lvl, from, to)
    placeCards(from, to)
    const word = openness(zoom) >= 0.5 ? "Items" : LEVELS[lvl].word
    if (word !== levelWord) level.value = levelWord = word

    paint()
    settleLater()
  }

  // ——— Moving ——————————————————————————————————————————————————————————

  function stop() {
    moving?.pause()
    moving = undefined
    steer = undefined
  }

  // Moves to an hour and a zoom, and brings a row to the middle, gliding in
  // under 300 ms or at once: the zoom eases by its ratio, and the hour moves
  // across the screen as evenly as the zoom allows.
  function go(x: number, zoom: number, toRow: number | undefined, glide: boolean) {
    stop()
    const target = clamp(zoom, ZOOM.min, ZOOM.max)
    if (toRow !== undefined) steer = {row: toRow, from: scroll, t: 0}
    if (!glide || still(root)) {
      if (steer) steer.t = 1
      camera.jumpTo(x, 0, target)
      render()
      steer = undefined
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
        if (steer) steer.t = state.t
        camera.jumpTo(x - (offset * (1 - state.t)) / at, 0, at)
      },
      onComplete: () => {
        moving = undefined
        steer = undefined
      },
    })
  }

  // The zoom a closer look at a square of level `lvl` goes to: the next level, across the screen.
  const closer = (lvl: number) =>
    lvl === 0
      ? Math.max(DAYS_FROM * 1.1, width / (168 * 1.15))
      : lvl === 1
        ? Math.max(HOURS_FROM * 1.1, width / (24 * 1.15))
        : LOOK

  function lookInto(spot: Spot, glide: boolean) {
    const lvl = levelNow()
    if (openness(camera.zoom) >= 0.5) return
    const length = LEVELS[lvl].hours
    cursor.row = spot.row
    cursor.at = spot.at
    go(spot.at + length / 2, closer(lvl), spot.row, glide)
  }

  const local = (clientX: number, clientY: number) => {
    const box = surface.getBoundingClientRect()
    return [clientX - box.left - surface.clientLeft, clientY - box.top - surface.clientTop] as const
  }

  // The square at a point of the surface, if there is a row there.
  function spotAt(x: number, y: number, into: Spot) {
    if (y < AXIS) return false
    const index = Math.floor(scroll + (y - AXIS) / row)
    // The row that folds the rest away holds nothing of its own while they are open.
    if (index < 0 || index >= shown.length || (index === toggle && opened)) return false
    into.row = index
    into.at = bucketOf(camera.x + (x - width / 2) / camera.zoom, LEVELS[levelNow()].hours)
    return true
  }

  const tapped: Spot = {row: 0, at: 0}

  function tap(clientX: number, clientY: number, target: EventTarget | null) {
    if (target instanceof Element && target.closest("a, button")) return
    const [x, y] = local(clientX, clientY)
    if (spotAt(x, y, tapped)) lookInto(tapped, !instant())
  }

  // ——— Words ———————————————————————————————————————————————————————————

  const titleOf = (index: number) => {
    const entry = shown[index]
    return entry ? entry.title : `${rows.length - FOLD} more projects`
  }

  function describe(spot: Spot) {
    const lvl = levelNow()
    const counts = countsAt(spot, lvl)
    const where = `${titleOf(spot.row)}, ${bucketLabel(LEVELS[lvl].span, spot.at)}`
    if (!counts) return where
    if (counts.changes === 0) return `${where}: nothing changed`
    const changes = counts.changes === 1 ? "1 change" : `${counts.changes.toLocaleString("en")} changes`
    const things = counts.things === 1 ? "1 thing" : `${counts.things.toLocaleString("en")} things`
    const keys = counts.together ? "" : counts.actors === 1 ? ", 1 Key" : `, ${counts.actors} Keys`
    return `${where}: ${changes}, ${things}${keys}`
  }

  const tipTitle = tip.appendChild(document.createElement("strong"))
  const tipWhen = tip.appendChild(document.createElement("span"))
  const tipCounts = tip.appendChild(document.createElement("span"))

  function showTip(x: number, y: number) {
    const lvl = levelNow()
    const counts = countsAt(hover, lvl)
    tipTitle.textContent = titleOf(hover.row)
    tipWhen.textContent = bucketLabel(LEVELS[lvl].span, hover.at)
    tipCounts.textContent = !counts
      ? ""
      : counts.changes === 0
        ? "Nothing changed"
        : [
            counts.changes === 1 ? "1 change" : `${counts.changes.toLocaleString("en")} changes`,
            counts.things === 1 ? "1 thing" : `${counts.things.toLocaleString("en")} things`,
            ...(counts.together ? [] : [counts.actors === 1 ? "1 Key" : `${counts.actors} Keys`]),
          ].join(" · ")
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
    said.textContent = describe(spot)
  }

  // Brings the keyboard's square into view, at once.
  function reveal() {
    const lvl = levelNow()
    const middle = cursor.at + LEVELS[lvl].hours / 2
    const x = screenX(middle)
    if (x < 24 || x > width - 24) camera.jumpTo(middle, 0)
    if (cursor.row < scroll) scroll = cursor.row
    else if (cursor.row + 1 > scroll + visibleRows()) scroll = cursor.row + 1 - visibleRows()
    render()
  }

  // ——— Listening ———————————————————————————————————————————————————————

  function keydown(event: KeyboardEvent) {
    if (event.altKey || event.ctrlKey || event.metaKey) return
    const card = event.target instanceof Element ? event.target.closest<HTMLElement>(".atlas-card") : null
    if (card) return cardKey(event, card)
    if (event.target !== stage) return
    keyed = true
    stop()
    const lvl = levelNow()
    const length = LEVELS[lvl].hours
    cursor.at = bucketOf(cursor.at, length)
    const moves: Record<string, [number, number]> = {
      ArrowLeft: [-1, 0],
      ArrowRight: [1, 0],
      ArrowUp: [0, -1],
      ArrowDown: [0, 1],
    }
    const move = moves[event.key]
    if (move) {
      event.preventDefault()
      cursor.at += move[0] * length
      cursor.row = clamp(cursor.row + move[1], 0, Math.max(0, shown.length - 1))
      reveal()
      say(cursor)
    } else if (event.key === "+" || event.key === "=" || event.key === "-" || event.key === "_") {
      event.preventDefault()
      const factor = event.key === "+" || event.key === "=" ? STEP : 1 / STEP
      const box = surface.getBoundingClientRect()
      anchor = clamp(rowTop(cursor.row) + row / 2 - AXIS, 0, height - AXIS)
      camera.zoomBy(factor, box.left + screenX(cursor.at + length / 2), box.top + anchor + AXIS)
      cursor.at = bucketOf(cursor.at, LEVELS[levelAt(camera.zoom)].hours)
      say(cursor)
    } else if (event.key === "Enter") {
      event.preventDefault()
      if (openness(camera.zoom) >= 0.5) {
        const first = grouped.get(bucketOf(cursor.at, 1))?.get(cursor.row)?.[0]
        const el = first && placed.get(first.id)
        if (el) el.querySelector<HTMLAnchorElement>(".atlas-card__title")!.focus({preventScroll: true})
        else say(cursor)
      } else {
        lookInto(cursor, false)
        cursor.at = bucketOf(cursor.at, LEVELS[levelNow()].hours)
        say(cursor)
      }
    }
  }

  // Tab and Shift+Tab step through the cards on screen in reading order and
  // leave at either end; Escape goes back to the picture.
  function cardKey(event: KeyboardEvent, card: HTMLElement) {
    if (event.key === "Escape") {
      event.preventDefault()
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
    anchor = clamp(y - AXIS, 0, height - AXIS)
    if (event.pointerType === "touch" || surface.hasAttribute("data-dragging")) return hideTip()
    if (event.target instanceof Element && event.target.closest(".atlas-card, .atlas-heat__more")) return hideTip()
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
      anchor = -1
      go(camera.x, camera.zoom * factor, undefined, byPointer(event) && !still(root))
      return
    }
    if (target?.closest("[data-atlas-rows] button")) {
      opened = !opened
      arrange()
      render()
    }
  }

  // A thing chosen in the strip beside the picture: its card, in its hour and its row.
  function focusThing(event: Event) {
    const {id, project, at} = (event as CustomEvent<{id: string; project: string; at: number}>).detail
    const hour = bucketOf(hourOf(at), 1)
    const index = rowFor(project) ?? 0
    pinned = id
    focusPinned = !lastInputByPointer()
    if (hours.has(hour)) group(hour)
    cursor.row = index
    cursor.at = hour
    go(hour + 0.5, Math.max(camera.zoom, LOOK), index, !instant())
  }

  const interrupt = () => stop()

  stage.addEventListener("keydown", keydown, listen)
  root.addEventListener("click", clicked, listen)
  root.addEventListener("atlas:focus", focusThing, listen)
  surface.addEventListener("pointermove", pointermove, listen)
  surface.addEventListener("pointerleave", hideTip, listen)
  surface.addEventListener(
    "pointerdown",
    () => {
      keyed = false
      interrupt()
    },
    {...listen, capture: true},
  )
  surface.addEventListener(
    "wheel",
    event => {
      anchor = clamp(local(event.clientX, event.clientY)[1] - AXIS, 0, height - AXIS)
      interrupt()
      hideTip()
    },
    {...listen, passive: true, capture: true},
  )
  stage.addEventListener("focus", () => paint(), listen)
  stage.addEventListener("blur", () => paint(), listen)
  // A wheel over the rows' names moves up and down them.
  rowsBox.addEventListener(
    "wheel",
    event => {
      event.preventDefault()
      stop()
      scroll += event.deltaY / row
      render()
    },
    {...listen, passive: false},
  )

  // ——— The window in the address ——————————————————————————————————————

  // Frames the window of `name` holding `hour`, across the screen.
  function frame(name: Window, hour: number, glide: boolean) {
    const [start, end] = windowOf(name, hour)
    go((start + end) / 2, width / ((end - start) * 1.04), undefined, glide)
  }

  function settleLater() {
    movedAt = performance.now()
    if (!settleTimer) settleTimer = window.setTimeout(settle, SETTLE)
  }

  // Once the view rests, the window in view is named in the address, unless it already is.
  function settle() {
    settleTimer = 0
    const idle = performance.now() - movedAt
    if (idle < SETTLE) {
      settleTimer = window.setTimeout(settle, SETTLE - idle)
      return
    }
    if (moving || !named) return
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

  // ——— The page ————————————————————————————————————————————————————————

  function forget() {
    generation += 1
    tiles.clear()
    asking.clear()
    stale.clear()
    hours.clear()
    askingHours.clear()
    staleHours.clear()
    grouped.clear()
    most.fill(0)
    for (const layer of layers) layer.dirty = true
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
    for (const key of tiles.keys()) stale.add(key)
    for (const hour of hours.keys()) staleHours.add(hour)
    asking.clear()
    askingHours.clear()
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
    render()
  })
  resize.observe(surface)

  if (!navigator.gpu) surface.dataset.atlasStill = "true"
  const controller = createCanvasIsland<HeatRenderer>(surface, {}, {
    canvasSelector: "[data-atlas-canvas]",
    readyFlag: "atlasReady",
    // The picture is the page's content, so it is drawn for every reader.
    motionSensitive: false,
    continuous: false,
    browserLoad: async (canvas, size, lost) => {
      const {createHeatRenderer} = await import("./renderer")
      return createHeatRenderer(canvas, size, lost)
    },
    interact: ({renderer, nudge, onReady}) => {
      island = {renderer, nudge}
      const retone = () => {
        renderer()?.tones(
          tone(surface, "--atlas-heat-empty"),
          tone(surface, "--atlas-heat-1"),
          tone(surface, "--atlas-heat-2"),
          tone(surface, "--atlas-heat-3"),
          tone(surface, "--color-focus"),
        )
        nudge()
      }
      onReady(() => {
        retone()
        layers.forEach((layer, slot) => renderer()?.cells(slot, data[slot], layer.count))
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
      window.clearTimeout(settleTimer)
      events.abort()
      resize.disconnect()
      camera.destroy()
      controller.destroy()
    },
  }
}
