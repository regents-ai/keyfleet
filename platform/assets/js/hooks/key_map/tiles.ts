import {axialToPixel, SQRT3} from "./lattice"
import type {KeyMapGrid} from "./layouts"

export type TileFaces = {
  /** A tile's marks for `data-state`. */
  marks(key: number): string
  /** The small line under a key's number. */
  caption(key: number): string
}

export type Tiles = {
  /**
   * Gives every key or level heading whose cell touches the world rectangle a
   * pooled element, and hides the rest of the pool.
   */
  place(grid: KeyMapGrid, size: number, left: number, top: number, right: number, bottom: number): void
  /** Rewrites the marks and captions on every placed key. */
  refresh(): void
  /** Frees every tile, so the next placement positions each one afresh. */
  clear(): void
}

type Tile = {el: HTMLElement; value: number; label: HTMLElement; caption: HTMLElement}

// Cells stay within a few copies of the origin, so both coordinates fit in 21 bits.
const cellId = (q: number, r: number) => (r + 2 ** 20) * 2 ** 21 + (q + 2 ** 20)

/**
 * The pool only grows to the most cells covered at once: the stage plus one
 * cell on every side, at most (w / cell + 5) × (h / (0.866 × cell) + 5)
 * elements, fewer where the map has gaps. The laptop stage (1,390 × 630 at
 * 96 px cells) needs at most 19 × 12 = 228 against a budget of 400, and the
 * phone stage (378 × 587 at 76 px) at most 9 × 13 = 117 against 160. A stage
 * wider than about 2,300 px would pass 400; the browser tests hold both
 * measured counts to their budgets.
 */
export function createTiles(layer: HTMLElement, faces: TileFaces): Tiles {
  let placed = new Map<number, Tile>()
  const spare: Tile[] = []

  const make = (): Tile => {
    const el = document.createElement("div")
    const label = document.createElement("span")
    const caption = document.createElement("span")
    el.append(label, caption)
    layer.append(el)
    return {el, value: 0, label, caption}
  }

  const free = (tile: Tile) => {
    tile.el.hidden = true
    spare.push(tile)
  }

  const face = (tile: Tile) => {
    if (tile.value <= 0) return
    const marks = faces.marks(tile.value)
    const caption = faces.caption(tile.value)
    if (tile.el.dataset.state !== marks) tile.el.dataset.state = marks
    if (tile.caption.textContent !== caption) tile.caption.textContent = caption
  }

  const paint = (tile: Tile, value: number) => {
    const {el} = tile
    el.hidden = false
    if (tile.value !== value) {
      tile.value = value
      el.className = value > 0 ? "km-tile" : "km-level"
      if (value > 0) el.dataset.key = String(value)
      else {
        delete el.dataset.key
        delete el.dataset.state
      }
      tile.label.textContent = value > 0 ? value.toLocaleString("en-US") : `Level ${-value}`
      tile.caption.textContent = ""
    }
    face(tile)
  }

  return {
    place(grid, size, left, top, right, bottom) {
      const rowPitch = 1.5 * size
      const colPitch = SQRT3 * size
      const next = new Map<number, Tile>()
      const needed: number[] = []
      // One cell of margin: the layout is redone whenever the camera crosses a
      // cell, so the view never moves more than a cell past what is placed.
      for (let r = Math.floor(top / rowPitch) - 1; r <= Math.ceil(bottom / rowPitch) + 1; r++) {
        for (let q = Math.floor(left / colPitch - r / 2) - 1; q <= Math.ceil(right / colPitch - r / 2) + 1; q++) {
          const value = grid.valueAt(q, r)
          if (!value) continue
          const id = cellId(q, r)
          const tile = placed.get(id)
          if (tile) {
            placed.delete(id)
            next.set(id, tile)
            if (tile.value !== value) paint(tile, value)
          } else needed.push(q, r, value)
        }
      }
      placed.forEach(free)
      for (let index = 0; index < needed.length; index += 3) {
        const [q, r, value] = [needed[index], needed[index + 1], needed[index + 2]]
        const tile = spare.pop() ?? make()
        paint(tile, value)
        const [x, y] = axialToPixel(q, r, size)
        tile.el.style.transform = `translate3d(${x}px, ${y}px, 0)`
        next.set(cellId(q, r), tile)
      }
      placed = next
    },

    refresh() {
      placed.forEach(face)
    },

    clear() {
      placed.forEach(free)
      placed = new Map()
    },
  }
}
