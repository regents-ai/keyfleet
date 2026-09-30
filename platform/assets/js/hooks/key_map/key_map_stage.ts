import {createCamera} from "./camera"
import {axialToPixel, nearestCopy, pixelToAxial, SQRT3, type Cell, type Point} from "./lattice"
import {buildMap, levelStart, type KeyMapGrid, type LayoutKind} from "./layouts"
import {
  applyPatch,
  availableKey,
  decodeSnapshot,
  describeKey,
  drawnKeys,
  keyMarks,
  keyNear,
  lastChoosable,
  levelHeading,
  levelSale,
  nextHeldKey,
  onSaleLevel,
  startKey,
  step,
  unsold,
  type Direction,
  type KeyMapPatch,
  type KeyMapSnapshot,
  type KeyMapState,
} from "./state"
import {createTiles} from "./tiles"

export type KeyMapStage = {
  /** Every key's marks. The key the page has chosen is read from `data-selected`. */
  load(snapshot: KeyMapSnapshot): void
  /** Marks for the keys that changed; ignored until the first load. */
  patch(patch: KeyMapPatch): void
  /** The key the page has chosen, or none. */
  select(key: number | null): void
  focusAvailable(): void
  /** The keyboard cursor moves to your next key, coming back round to the first. */
  focusMine(): void
  focusLevel(level: number): void
  destroy(): void
}

export type KeyMapStageOptions = {
  layout: LayoutKind
  /** A key was chosen by click, tap or Enter. */
  select(key: number): void
}

const recentreDistance = 100_000
// How long the mouse rests on a key before its note shows.
const noteRest = 300
const noteText = "The preceding key must be sold."

const arrows: Record<string, Direction> = {
  ArrowLeft: "left",
  ArrowRight: "right",
  ArrowUp: "up",
  ArrowDown: "down",
}

/**
 * The key map inside its stage element: a pool of hex tiles on one layer that
 * the camera moves, repeating the fleet's map in every direction.
 *
 * Panels may open over the stage's right-hand side; the elements named by the
 * stage's `data-covered-by` selector are those panels. The map centres in the
 * part they leave uncovered.
 */
export function createKeyMapStage(root: HTMLElement, options: KeyMapStageOptions): KeyMapStage {
  const layer = document.createElement("div")
  layer.className = "km-layer"
  layer.setAttribute("aria-hidden", "true")
  const status = document.createElement("p")
  status.className = "visually-hidden"
  status.setAttribute("aria-live", "polite")
  // A key that can't be bought yet says why, in a note that sits on the
  // moving layer above its key, so it follows the key as the map moves.
  const note = document.createElement("p")
  note.className = "km-note"
  note.textContent = noteText
  note.hidden = true
  layer.append(note)
  root.replaceChildren(layer, status)

  const motion = window.matchMedia("(prefers-reduced-motion: reduce)")
  let grid: KeyMapGrid | null = null
  let state: KeyMapState | null = null
  let selected = 0
  let cursor: Cell | null = null
  // Circumradius of a cell and the stage's size, in CSS pixels.
  let size = 0
  let width = 0
  let height = 0
  // The middle and width of the part of the stage no panel covers.
  let middle = 0
  let across = 0
  let placedAt = ""
  // The cell whose note shows, and the wait for a resting mouse.
  let noteCell: Cell | null = null
  let rest = 0

  const cursorKey = () => (cursor && grid ? grid.valueAt(...cursor) : 0)

  const choosable = (key: number) => key >= 1 && key <= lastChoosable(state!)

  const drawn = (of: KeyMapState) => drawnKeys(options.layout, of)

  const tiles = createTiles(layer, {
    marks: key => keyMarks(state!, key, selected, cursorKey()),
    caption: key => (key === availableKey(state!) ? "Available" : ""),
    sale: level => levelSale(onSaleLevel(grid!, state!), level),
    heading: level => levelHeading(level, levelSale(onSaleLevel(grid!, state!), level)),
  })

  const periods = (): [Point, Point] => [axialToPixel(...grid!.periodA, size), axialToPixel(...grid!.periodB, size)]

  // Brings the camera back near the origin by whole copies of the map once it
  // has travelled far, so positions stay precise in the browser's 32-bit
  // transforms (0.01 px at this distance). The picture is unchanged, but every
  // tile is placed afresh, so it happens only every 100,000 px or so.
  const recentre = () => {
    if (Math.hypot(camera.x, camera.y) < recentreDistance) return
    const [a, b] = periods()
    const det = a[0] * b[1] - a[1] * b[0]
    const i = Math.round((camera.x * b[1] - camera.y * b[0]) / det)
    const j = Math.round((a[0] * camera.y - a[1] * camera.x) / det)
    if (i === 0 && j === 0) return
    camera.shift(-(i * a[0] + j * b[0]), -(i * a[1] + j * b[1]))
    if (cursor) cursor = [cursor[0] - i * grid!.periodA[0] - j * grid!.periodB[0], cursor[1] - i * grid!.periodA[1] - j * grid!.periodB[1]]
    noteOn(null)
    placedAt = ""
  }

  const render = () => {
    if (!grid) return
    recentre()
    const {x, y, zoom} = camera
    layer.style.transform = `translate3d(${middle - x * zoom}px, ${height / 2 - y * zoom}px, 0) scale(${zoom})`
    const [left, top] = [x - middle / zoom, y - height / 2 / zoom]
    const cell = `${Math.floor(left / (SQRT3 * size))},${Math.floor(top / (1.5 * size))},${zoom}`
    if (cell === placedAt) return
    placedAt = cell
    tiles.place(grid, size, left, top, x + (width - middle) / zoom, y + height / 2 / zoom)
  }

  const camera = createCamera(root, {
    onFrame: render,
    // A press ends the opening zoom, so the map is at normal size by now.
    onTap: (clientX, clientY) => {
      if (!grid) return
      const value = grid.valueAt(...cellAt(clientX, clientY))
      if (choosable(value)) choose(value)
    },
    reducedMotion: () => motion.matches,
  })

  const choose = (key: number) => {
    selected = key
    tiles.refresh()
    options.select(key)
  }

  const centreCell = () => pixelToAxial(camera.x, camera.y, size)

  // The cell under a point on screen, with the map at normal size.
  const cellAt = (clientX: number, clientY: number) => {
    const rect = root.getBoundingClientRect()
    const x = clientX - rect.left - root.clientLeft - middle + camera.x
    const y = clientY - rect.top - root.clientTop - height / 2 + camera.y
    return pixelToAxial(x, y, size)
  }

  // Shows the note above a key that can't be bought yet, and hides it for any
  // other cell.
  const noteOn = (cell: Cell | null) => {
    const key = cell && grid && state ? grid.valueAt(...cell) : 0
    noteCell = key > 0 && unsold(state!, key) ? cell : null
    note.hidden = !noteCell
    if (!noteCell) return
    const [x, y] = axialToPixel(...noteCell, size)
    note.style.transform = `translate3d(${x}px, ${y - size}px, 0)`
  }

  const hideNote = () => {
    clearTimeout(rest)
    noteOn(null)
  }

  // The copy of a key nearest the middle of the view.
  const nearestCell = (key: number) => {
    const [a, b] = periods()
    const [x, y] = nearestCopy(axialToPixel(...grid!.home(key), size), [camera.x, camera.y], a, b)
    return pixelToAxial(x, y, size)
  }

  // Moves the keyboard cursor, reads the key out and keeps it in view.
  const moveCursor = (cell: Cell, centre: boolean) => {
    cursor = cell
    tiles.refresh()
    status.textContent = describeKey(grid!, state!, cursorKey())
    noteOn(cell)
    bringIntoView(cell, centre)
  }

  const bringIntoView = (cell: Cell, centre: boolean) => {
    const [x, y] = axialToPixel(...cell, size)
    const margin = SQRT3 * size
    const hidden = Math.abs(x - camera.x) > across / 2 - margin || Math.abs(y - camera.y) > height / 2 - margin
    if (centre || hidden) camera.glideTo(x, y)
  }

  // Keyfleet Classic opens on its whole pyramid, every row drawn, fitted into
  // the uncovered part of the stage with half a cell to spare on every side
  // and never drawn larger than normal, then zooms in to (x, y).
  const zoomInFromWhole = (x: number, y: number) => {
    let [minX, minY, maxX, maxY] = [Infinity, Infinity, -Infinity, -Infinity]
    for (let key = 1; key <= drawn(state!); key++) {
      const [px, py] = axialToPixel(...grid!.home(key), size)
      ;[minX, minY, maxX, maxY] = [Math.min(minX, px), Math.min(minY, py), Math.max(maxX, px), Math.max(maxY, py)]
    }
    const zoom = Math.min(1, across / (maxX - minX + 2 * SQRT3 * size), height / (maxY - minY + 2 * size + SQRT3 * size))
    camera.zoomIn((minX + maxX) / 2, (minY + maxY) / 2, zoom, x, y)
  }

  // The cursor goes to a key shown on the map, in the view's middle.
  const focusKey = (key: number) => {
    if (grid && state && key >= 1 && key <= drawn(state)) moveCursor(nearestCell(key), true)
  }

  // Draws `next`. The view stays on the keys it was showing: the camera is
  // held as an offset from the key nearest the middle, then restored from
  // that key's home cell. The first drawing opens on the chosen key, or else
  // the available key; Classic's zooms in to it from the whole pyramid.
  const show = (next: KeyMapState) => {
    const first = !grid
    const anchor = grid && keyNear(grid, centreCell())
    const kept = anchor && grid!.valueAt(...anchor) <= drawn(next) ? anchor : null
    const cursorWas = cursorKey()
    const key = kept ? grid!.valueAt(...kept) : selected || startKey(next)
    const [fromX, fromY] = kept ? axialToPixel(...kept, size) : [camera.x, camera.y]
    grid = buildMap(options.layout, drawn(next))
    state = next
    tiles.clear()
    placedAt = ""
    const [x, y] = axialToPixel(...grid.home(key), size)
    if (kept) camera.shift(x - fromX, y - fromY)
    else if (first && options.layout === "classic") zoomInFromWhole(x, y)
    else camera.jumpTo(x, y)
    cursor = cursorWas && cursorWas <= drawn(next) ? nearestCell(cursorWas) : null
    if (!cursor) status.textContent = ""
    noteOn(null)
    render()
  }

  // Shortcuts with Alt, Control or Command belong to the browser. Space never
  // scrolls the page while the map has focus; like Enter, it chooses the key
  // under the cursor when there is one.
  const keydown = (event: KeyboardEvent) => {
    if (!grid || !state || event.altKey || event.ctrlKey || event.metaKey) return
    // A key pressed during the opening zoom ends it.
    if (camera.zoom !== 1) camera.stop()
    const direction = arrows[event.key]
    if (direction) {
      event.preventDefault()
      const cell = cursor ? step(grid, cursor, direction) : keyNear(grid, centreCell())
      if (cell) moveCursor(cell, false)
    } else if (event.key === "Home") {
      event.preventDefault()
      moveCursor(nearestCell(startKey(state)), true)
    } else if (event.key === "Enter" || event.key === " ") {
      if (cursor || event.key === " ") event.preventDefault()
      if (cursor && choosable(cursorKey())) choose(cursorKey())
    } else if (event.key === "Escape" && cursor) {
      cursor = null
      status.textContent = ""
      noteOn(null)
      tiles.refresh()
    }
  }

  // A mouse resting on a key that can't be bought yet shows its note. Any
  // press or wheel, or a move off the key, hides it until the mouse rests
  // again.
  const hover = (event: PointerEvent) => {
    clearTimeout(rest)
    if (event.pointerType === "touch" || event.buttons !== 0 || !grid || camera.zoom !== 1) return hideNote()
    const cell = cellAt(event.clientX, event.clientY)
    if (noteCell && cell[0] === noteCell[0] && cell[1] === noteCell[1]) return
    noteOn(null)
    rest = window.setTimeout(() => noteOn(cell), noteRest)
  }

  const covers = root.dataset.coveredBy ? [...document.querySelectorAll<HTMLElement>(root.dataset.coveredBy)] : []

  // A panel covers the stage from its left edge rightwards; a closed panel
  // has no width, and one that covers the whole stage leaves nothing to
  // centre in, so the map centres in the whole stage behind it. When the
  // uncovered part changes, the camera moves with its middle, so the picture
  // stays where it was.
  const measure = () => {
    const cell = parseFloat(getComputedStyle(root).getPropertyValue("--km-cell"))
    const nextSize = cell / SQRT3
    if (size && nextSize !== size) {
      camera.scale(nextSize / size)
      tiles.clear()
      noteOn(null)
    }
    size = nextSize
    width = root.clientWidth
    height = root.clientHeight
    const stageLeft = root.getBoundingClientRect().left + root.clientLeft
    across = covers.reduce((open, panel) => {
      const {left, width: panelWidth} = panel.getBoundingClientRect()
      return panelWidth && left > stageLeft ? Math.min(open, left - stageLeft) : open
    }, width)
    camera.x += (across / 2 - middle) / camera.zoom
    middle = across / 2
    placedAt = ""
    render()
  }

  const resize = new ResizeObserver(measure)
  resize.observe(root)
  covers.forEach(panel => resize.observe(panel))
  root.addEventListener("keydown", keydown)
  root.addEventListener("pointermove", hover)
  root.addEventListener("pointerleave", hideNote)
  root.addEventListener("pointerdown", hideNote)
  root.addEventListener("wheel", hideNote, {passive: true})
  root.addEventListener("blur", hideNote)
  measure()

  return {
    load(snapshot) {
      // The page, not the map, keeps the chosen key.
      selected = Number(root.dataset.selected) || 0
      show(decodeSnapshot(snapshot))
      root.classList.add("key-map--ready")
    },

    patch(patch) {
      if (!state) return
      const next = applyPatch(state, patch)
      if (drawn(next) !== drawn(state)) return show(next)
      state = next
      tiles.refresh()
      noteOn(noteCell)
    },

    select(key) {
      selected = key ?? 0
      if (!grid || !state) return
      tiles.refresh()
      if (choosable(selected)) bringIntoView(nearestCell(selected), false)
    },

    focusAvailable() {
      if (state) focusKey(availableKey(state))
    },

    focusMine() {
      if (!state) return
      const key = nextHeldKey(state, cursorKey())
      if (key) focusKey(key)
      else status.textContent = "You don’t hold any keys in this fleet."
    },

    focusLevel(level) {
      focusKey(levelStart(level))
    },

    destroy() {
      camera.destroy()
      resize.disconnect()
      clearTimeout(rest)
      root.removeEventListener("keydown", keydown)
      root.removeEventListener("pointermove", hover)
      root.removeEventListener("pointerleave", hideNote)
      root.removeEventListener("pointerdown", hideNote)
      root.removeEventListener("wheel", hideNote)
      root.removeEventListener("blur", hideNote)
    },
  }
}
