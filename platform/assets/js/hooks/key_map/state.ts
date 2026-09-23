import {axialToOffset, hexDistance, offsetToAxial, type Cell} from "./lattice"
import {fibonacciLevelSupplies, type KeyMapGrid, type LayoutKind} from "./layouts"

/** The server's reply to `keymap_ready`. */
export type KeyMapSnapshot = {
  minted: number
  max_supply: number
  /** Base64 bitsets; bit `id − 1` sits in byte `(id − 1) >> 3`, least significant bit first. */
  mine: string
  agent: string
}

/** Keys whose marks changed: `[token_id, flags]`, bit 0 yours and bit 1 has an agent. */
export type KeyMapPatch = {
  minted: number
  keys: [number, number][]
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

const setBit = (bits: Uint8Array, key: number, on: boolean) => {
  const mask = 1 << ((key - 1) & 7)
  bits[(key - 1) >> 3] = on ? bits[(key - 1) >> 3] | mask : bits[(key - 1) >> 3] & ~mask
}

/** The state after a patch; the state given is left as it was. */
export function applyPatch(state: KeyMapState, patch: KeyMapPatch): KeyMapState {
  const mine = state.mine.slice()
  const agent = state.agent.slice()
  for (const [key, flags] of patch.keys) {
    setBit(mine, key, (flags & 1) === 1)
    setBit(agent, key, (flags & 2) === 2)
  }
  return {...state, minted: patch.minted, mine, agent}
}

/** The last key that can be chosen: the next key, or the last key once the fleet is sold out. */
export const lastChoosable = (state: KeyMapState) => Math.min(state.minted + 1, state.maxSupply)

/** The key on sale, or 0 once the fleet is sold out. */
export const nextKey = (state: KeyMapState) => (state.minted < state.maxSupply ? state.minted + 1 : 0)

/**
 * How many keys the map draws, the one place that decides it: every key sold,
 * the rest of the level on sale and the whole level after it. A fleet without
 * levels is drawn whole.
 */
export function drawnKeys(layout: LayoutKind, state: KeyMapState) {
  const next = nextKey(state)
  if (layout !== "fibonacci" || !next) return state.maxSupply
  return Math.min(levelStart(fibonacciLevelOf(next) + 2) - 1, state.maxSupply)
}

/** The Fibonacci level a key belongs to. */
export function fibonacciLevelOf(key: number) {
  let last = 0
  for (const [index, supply] of fibonacciLevelSupplies.entries()) {
    last += supply
    if (key <= last) return index + 1
  }
  return fibonacciLevelSupplies.length
}

/** The level of the key on sale, or 0 once the fleet is sold out or for a fleet without levels. */
export const onSaleLevel = (grid: KeyMapGrid, state: KeyMapState) => {
  const next = nextKey(state)
  return next ? grid.levelOf(next) : 0
}

/** How a level stands: sold out, on sale now, or not on sale yet. */
export type LevelSale = "sold-out" | "on-sale" | "upcoming"

/** Where a level stands against the level on sale; every level is sold out once the fleet is. */
export function levelSale(onSale: number, level: number): LevelSale {
  if (!onSale || level < onSale) return "sold-out"
  return level === onSale ? "on-sale" : "upcoming"
}

/** How many tones the levels step through; neighbouring levels always differ. */
export const levelTones = 4

/** A level's tone, from 0: level 1 takes the first and the tones repeat in order. */
export const levelTone = (level: number) => (level - 1) % levelTones

/** A level heading's words. */
export function levelHeading(level: number, sale: LevelSale) {
  if (sale === "sold-out") return `Level ${level} · sold out`
  return sale === "on-sale" ? `Level ${level} · on sale now` : `Level ${level}`
}

/** Where the map opens and where Home goes: the next key, or key 1 once sold out. */
export const startKey = (state: KeyMapState) => nextKey(state) || 1

/**
 * The first key after `after` that is yours, coming back round to key 1 past
 * the next key, or 0 when you hold none.
 */
export function nextHeldKey(state: KeyMapState, after: number) {
  const shown = lastChoosable(state)
  for (let step = 1; step <= shown; step++) {
    const key = ((after + step - 1) % shown) + 1
    if (hasBit(state.mine, key)) return key
  }
  return 0
}

/** The first key of a Fibonacci level. */
export const levelStart = (level: number) =>
  fibonacciLevelSupplies.slice(0, level - 1).reduce((total, supply) => total + supply, 1)

/** A key drawn but not sold, other than the next key, which can't be chosen yet. */
const unsold = (state: KeyMapState, key: number) => key > state.minted + 1

/** A tile's marks, for `data-state`. */
export function keyMarks(state: KeyMapState, key: number, selected: number, cursor: number) {
  const marks: string[] = []
  if (key === nextKey(state)) marks.push("next")
  if (unsold(state, key)) marks.push("unsold")
  if (hasBit(state.mine, key)) marks.push("mine")
  if (hasBit(state.agent, key)) marks.push("agent")
  if (key === selected) marks.push("selected")
  if (key === cursor) marks.push("cursor")
  return marks.join(" ")
}

// One formatter for every number the map shows: making one per number, as
// `toLocaleString` does, is most of the cost of drawing a key.
const grouping = new Intl.NumberFormat("en-US")

/** A number with its thousands grouped, as 17,769. */
export const grouped = (value: number) => grouping.format(value)

/** What the map reads out when the keyboard cursor lands on a key. */
export function describeKey(grid: KeyMapGrid, state: KeyMapState, key: number) {
  const level = grid.levelOf(key)
  const parts = [key === nextKey(state) ? `Next key, ${grouped(key)}` : `Key ${grouped(key)}`]
  if (level) parts.push(`level ${level}`)
  if (hasBit(state.mine, key)) parts.push("yours")
  if (hasBit(state.agent, key)) parts.push("has an agent")
  if (unsold(state, key)) parts.push("not sold yet")
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
