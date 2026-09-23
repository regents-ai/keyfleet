import {axialToOffset, hexDistance, offsetToAxial, type Cell} from "./lattice"
import type {KeyMapGrid} from "./layouts"

/** The server's reply to `keymap_ready`. */
export type KeyMapSnapshot = {
  minted: number
  max_supply: number
  /** Base64 bitsets; bit `id − 1` sits in byte `(id − 1) >> 3`, least significant bit first. */
  mine: string
  agent: string
}

export type KeyMapState = {
  minted: number
  maxSupply: number
  mine: Uint8Array
  agent: Uint8Array
}

export type Direction = "left" | "right" | "up" | "down"

const decodeBits = (base64: string) => Uint8Array.from(atob(base64), character => character.charCodeAt(0))

export const decodeSnapshot = (snapshot: KeyMapSnapshot): KeyMapState => ({
  minted: snapshot.minted,
  maxSupply: snapshot.max_supply,
  mine: decodeBits(snapshot.mine),
  agent: decodeBits(snapshot.agent),
})

export const hasBit = (bits: Uint8Array, key: number) => ((bits[(key - 1) >> 3] >> ((key - 1) & 7)) & 1) === 1

/** Keys drawn: every sold key plus the next one. */
export const shownKeys = (state: KeyMapState) => Math.min(state.minted + 1, state.maxSupply)

/** The key on sale, or 0 once the fleet is sold out. */
export const nextKey = (state: KeyMapState) => (state.minted < state.maxSupply ? state.minted + 1 : 0)

/** Where the map opens and where Home goes: the next key, or key 1 once sold out. */
export const startKey = (state: KeyMapState) => nextKey(state) || 1

/** A tile's marks, for `data-state`. */
export function keyMarks(state: KeyMapState, key: number, selected: number, cursor: number) {
  const marks: string[] = []
  if (key === nextKey(state)) marks.push("next")
  if (hasBit(state.mine, key)) marks.push("mine")
  if (hasBit(state.agent, key)) marks.push("agent")
  if (key === selected) marks.push("selected")
  if (key === cursor) marks.push("cursor")
  return marks.join(" ")
}

const grouped = (value: number) => value.toLocaleString("en-US")

/** What the map reads out when the keyboard cursor lands on a key. */
export function describeKey(grid: KeyMapGrid, state: KeyMapState, key: number) {
  const level = grid.levelOf(key)
  const parts = [key === nextKey(state) ? `Next key, ${grouped(key)}` : `Key ${grouped(key)}`]
  if (level) parts.push(`level ${level}`)
  if (hasBit(state.mine, key)) parts.push("yours")
  if (hasBit(state.agent, key)) parts.push("has an agent")
  return `${parts.join(", ")}.`
}

const isKey = (grid: KeyMapGrid, cell: Cell) => grid.valueAt(...cell) > 0

/**
 * The next key from `cell` in a direction, skipping empty cells. Left and right
 * follow the row; up and down keep the offset column. The map repeats, so the
 * walk always comes back round to a key.
 */
export function step(grid: KeyMapGrid, cell: Cell, direction: Direction): Cell {
  const horizontal = direction === "left" || direction === "right"
  const delta = direction === "left" || direction === "up" ? -1 : 1
  const [col, row] = axialToOffset(...cell)
  const limit = horizontal ? Math.abs(grid.periodA[0]) : 2 * Math.abs(grid.periodB[1])
  for (let distance = 1; distance <= limit; distance++) {
    const next = horizontal ? ([cell[0] + delta * distance, cell[1]] as const) : offsetToAxial(col, row + delta * distance)
    if (isKey(grid, next)) return next
  }
  return cell
}

/**
 * The key cell nearest `cell`, searching outward ring by ring, or null for a
 * map with no keys. Every cell is within one copy's span of a copy of each
 * key, so the search stops there.
 */
export function keyNear(grid: KeyMapGrid, cell: Cell): Cell | null {
  if (isKey(grid, cell)) return cell
  const span = hexDistance(...grid.periodA) + hexDistance(...grid.periodB)
  for (let radius = 1; radius <= span; radius++) {
    for (let dq = -radius; dq <= radius; dq++) {
      for (let dr = Math.max(-radius, -dq - radius); dr <= Math.min(radius, -dq + radius); dr++) {
        const candidate: Cell = [cell[0] + dq, cell[1] + dr]
        if (hexDistance(dq, dr) === radius && isKey(grid, candidate)) return candidate
      }
    }
  }
  return null
}
