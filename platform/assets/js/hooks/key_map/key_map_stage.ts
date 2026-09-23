import {createCamera} from "./camera"
import {axialToPixel, nearestCopy, pixelToAxial, SQRT3, type Cell, type Point} from "./lattice"
import {buildMap, type KeyMapGrid, type LayoutKind} from "./layouts"
import {
  applyPatch,
  decodeSnapshot,
  describeKey,
  drawnKeys,
  keyMarks,
  keyNear,
  lastChoosable,
  levelHeading,
  levelSale,
  levelStart,
  nextHeldKey,
  nextKey,
  onSaleLevel,
  startKey,
  step,
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
  focusNext(): void
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

const arrows: Record<string, Direction> = {
  ArrowLeft: "left",
  ArrowRight: "right",
  ArrowUp: "up",
  ArrowDown: "down",
}

/**
 * The key map inside its stage element: a pool of hex tiles on one layer that
 * the camera moves, repeating the fleet's map in every direction.
 */
export function createKeyMapStage(root: HTMLElement, options: KeyMapStageOptions): KeyMapStage {
  const layer = document.createElement("div")
  layer.className = "km-layer"
  layer.setAttribute("aria-hidden", "true")
  const status = document.createElement("p")
  status.className = "visually-hidden"
  status.setAttribute("aria-live", "polite")
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
  let placedAt = ""

  const cursorKey = () => (cursor && grid ? grid.valueAt(...cursor) : 0)

  const drawn = (of: KeyMapState) => drawnKeys(options.layout, of)
  const choosable = (key: number) => key >= 1 && key <= lastChoosable(state!)

  const tiles = createTiles(layer, {
    marks: key => keyMarks(state!, key, selected, cursorKey()),
    caption: key => (key === nextKey(state!) ? "Next" : ""),
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
    placedAt = ""
  }

  const render = () => {
    if (!grid) return
    recentre()
    layer.style.transform = `translate3d(${width / 2 - camera.x}px, ${height / 2 - camera.y}px, 0)`
    const cell = `${Math.floor(camera.x / (SQRT3 * size))},${Math.floor(camera.y / (1.5 * size))}`
    if (cell === placedAt) return
    placedAt = cell
    tiles.place(grid, size, camera.x - width / 2, camera.y - height / 2, camera.x + width / 2, camera.y + height / 2)
  }

  const camera = createCamera(root, {
    onFrame: render,
    onTap: (clientX, clientY) => {
      if (!grid) return
      const rect = root.getBoundingClientRect()
      const x = clientX - rect.left - root.clientLeft - width / 2 + camera.x
      const y = clientY - rect.top - root.clientTop - height / 2 + camera.y
      const value = grid.valueAt(...pixelToAxial(x, y, size))
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
    bringIntoView(cell, centre)
  }

  const bringIntoView = (cell: Cell, centre: boolean) => {
    const [x, y] = axialToPixel(...cell, size)
    const margin = SQRT3 * size
    const hidden = Math.abs(x - camera.x) > width / 2 - margin || Math.abs(y - camera.y) > height / 2 - margin
    if (centre || hidden) camera.glideTo(x, y)
  }

  // The cursor goes to a key shown on the map, in the view's middle.
  const focusKey = (key: number) => {
    if (grid && state && key >= 1 && key <= drawn(state)) moveCursor(nearestCell(key), true)
  }

  // Draws `next`. The view stays on the keys it was showing: the camera is
  // held as an offset from the key nearest the middle, then restored from
  // that key's home cell. The first drawing opens on the chosen key, or else
  // the next key.
  const show = (next: KeyMapState) => {
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
    else camera.jumpTo(x, y)
    cursor = cursorWas && cursorWas <= drawn(next) ? nearestCell(cursorWas) : null
    if (!cursor) status.textContent = ""
    render()
  }

  // Shortcuts with Alt, Control or Command belong to the browser. Space never
  // scrolls the page while the map has focus; like Enter, it chooses the key
  // under the cursor when there is one.
  const keydown = (event: KeyboardEvent) => {
    if (!grid || !state || event.altKey || event.ctrlKey || event.metaKey) return
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
      tiles.refresh()
    }
  }

  const measure = () => {
    const cell = parseFloat(getComputedStyle(root).getPropertyValue("--km-cell"))
    const nextSize = cell / SQRT3
    if (size && nextSize !== size) {
      camera.scale(nextSize / size)
      tiles.clear()
    }
    size = nextSize
    width = root.clientWidth
    height = root.clientHeight
    placedAt = ""
    render()
  }

  const resize = new ResizeObserver(measure)
  resize.observe(root)
  root.addEventListener("keydown", keydown)
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
    },

    select(key) {
      selected = key ?? 0
      if (!grid || !state) return
      tiles.refresh()
      if (choosable(selected)) bringIntoView(nearestCell(selected), false)
    },

    focusNext() {
      if (state) focusKey(nextKey(state))
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
      root.removeEventListener("keydown", keydown)
    },
  }
}
