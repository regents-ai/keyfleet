import {axialToPixel, SQRT3, type Point} from "./lattice"
import {buildMap, maxSupply, type KeyMapGrid, type LayoutKind} from "./layouts"
import {
  availableKey,
  drawnKeys,
  levelSale,
  levelTone,
  onSaleLevel,
  startKey,
  type KeyMapState,
  type LevelSale,
} from "./state"

// A cell's circumradius and the view's size, in the drawing's own units: about
// twelve keys across, framed the way the map opens.
const size = 10
const width = 12 * SQRT3 * size
const height = width * 0.625
// Each hexagon is drawn a little inside its cell, leaving the map's gap.
const inset = 0.88
const corners = Array.from({length: 6}, (_, index) => {
  const angle = (Math.PI / 3) * index - Math.PI / 2
  return [Math.cos(angle) * size * inset, Math.sin(angle) * size * inset] as const
})

// The frame's middle. Accelerant's chain is framed across its whole width,
// windings 0 to 8 cells across, and no higher than its first four windings and
// bends, so it reads as a chain; the other fleets centre on the key they open on.
function frameMiddle(layout: LayoutKind, grid: KeyMapGrid, key: number): Point {
  const [x, y] = axialToPixel(...grid.home(key), size)
  return layout === "accelerant" ? [4 * SQRT3 * size, Math.max(y, 3.5 * 1.5 * size)] : [x, y]
}

export type PreviewTile = {
  key: number
  /** The hexagon's corners, as SVG `points`. */
  points: string
  /** The level's tone and sale, for a fleet with levels. */
  tone?: number
  level?: LevelSale
  mark?: "available" | "unsold"
}

export type Preview = {viewBox: string; tiles: PreviewTile[]}

/**
 * A still picture of a fleet's map as it opens, once `minted` keys are sold:
 * the keys around the available key (key 1 once sold out), in the map's own
 * layout, tones and marks. Accelerant's is framed on its chain.
 */
export function preview(layout: LayoutKind, minted: number): Preview {
  const state: KeyMapState = {minted, maxSupply: maxSupply[layout], mine: new Uint8Array(0), agent: new Uint8Array(0)}
  const grid = buildMap(layout, drawnKeys(layout, state))
  const available = availableKey(state)
  const onSale = onSaleLevel(grid, state)
  const [cx, cy] = frameMiddle(layout, grid, startKey(state))
  const tiles: PreviewTile[] = []

  const rowFrom = Math.floor((cy - height / 2) / (1.5 * size)) - 1
  const rowTo = Math.ceil((cy + height / 2) / (1.5 * size)) + 1
  for (let r = rowFrom; r <= rowTo; r++) {
    const qFrom = Math.floor((cx - width / 2) / (SQRT3 * size) - r / 2) - 1
    const qTo = Math.ceil((cx + width / 2) / (SQRT3 * size) - r / 2) + 1
    for (let q = qFrom; q <= qTo; q++) {
      const key = grid.valueAt(q, r)
      if (key <= 0) continue
      const [x, y] = axialToPixel(q, r, size)
      const tile: PreviewTile = {key, points: corners.map(([dx, dy]) => `${x + dx},${y + dy}`).join(" ")}
      const level = grid.levelOf(key)
      if (level) {
        tile.tone = levelTone(level)
        tile.level = levelSale(onSale, level)
      }
      if (key === available) tile.mark = "available"
      else if (key > minted) tile.mark = "unsold"
      tiles.push(tile)
    }
  }

  return {viewBox: `${cx - width / 2} ${cy - height / 2} ${width} ${height}`, tiles}
}

const svg = "http://www.w3.org/2000/svg"

/** Draws `preview(layout, minted)` as an SVG, replacing everything inside `root`. */
export function drawPreview(root: Element, layout: LayoutKind, minted: number) {
  const {viewBox, tiles} = preview(layout, minted)
  const drawing = document.createElementNS(svg, "svg")
  drawing.setAttribute("viewBox", viewBox)
  drawing.setAttribute("preserveAspectRatio", "xMidYMid slice")
  for (const {points, tone, level, mark} of tiles) {
    const polygon = document.createElementNS(svg, "polygon")
    polygon.setAttribute("points", points)
    if (tone !== undefined) polygon.dataset.tone = String(tone)
    if (level) polygon.dataset.level = level
    if (mark) polygon.dataset.state = mark
    drawing.append(polygon)
  }
  root.replaceChildren(drawing)
}
