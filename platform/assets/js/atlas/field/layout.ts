/**
 * Where everything sits in the Atlas field, as plain arithmetic, so the same
 * project, kind, hour and thing land in the same place on every visit.
 *
 * The world is measured in units where one project's cluster is `CLUSTER`
 * across. Clusters lie on a sunflower spiral by rank, the busiest in the
 * middle (`clusterAt`). A cluster is a square of kinds, one patch for each
 * (`petalAt`), and each patch is a square spiral of the window's hours
 * (`spiralAt`): the first hour in the middle, every later hour beside the one
 * before it, the newest on the outside. A spiral rather than rings because
 * neighbouring hours stay neighbours, every hour gets the same room so
 * density reads as work, and new hours land outside everything already drawn,
 * so nothing ever moves as time passes. Square cells hold a grid of cards.
 */

/** A cluster's width in world units, whatever the window. */
export const CLUSTER = 100

/** The sunflower spiral's step: clusters keep at least 40 units apart. */
export const SPACING = 190

const GOLDEN = Math.PI * (3 - Math.sqrt(5))

/** The middle of the cluster of the project ranked `rank`, the busiest 0. */
export function clusterAt(rank: number, out: [number, number] = [0, 0]): [number, number] {
  const radius = SPACING * Math.sqrt(rank)
  out[0] = radius * Math.cos(rank * GOLDEN)
  out[1] = radius * Math.sin(rank * GOLDEN)
  return out
}

/** The radius every cluster up to `count` lies within, cluster included. */
export const fleetRadius = (count: number) => SPACING * Math.sqrt(Math.max(0, count - 1)) + CLUSTER * 0.71

/**
 * A cell on the square spiral: index 0 in the middle, then each ring around
 * it, starting just below its right-hand corner and going round.
 */
export function spiralAt(index: number, out: [number, number] = [0, 0]): [number, number] {
  if (index <= 0) {
    out[0] = 0
    out[1] = 0
    return out
  }
  const ring = Math.ceil((Math.sqrt(index + 1) - 1) / 2)
  const along = index - (2 * ring - 1) ** 2
  const side = 2 * ring
  if (along < side) {
    out[0] = ring
    out[1] = -ring + 1 + along
  } else if (along < 2 * side) {
    out[0] = ring - 1 - (along - side)
    out[1] = ring
  } else if (along < 3 * side) {
    out[0] = -ring
    out[1] = ring - 1 - (along - 2 * side)
  } else {
    out[0] = -ring + 1 + (along - 3 * side)
    out[1] = -ring
  }
  return out
}

/** The index of the cell at `x`, `y` on the square spiral. */
export function spiralIndex(x: number, y: number) {
  const ring = Math.max(Math.abs(x), Math.abs(y))
  if (ring === 0) return 0
  const first = (2 * ring - 1) ** 2
  const side = 2 * ring
  if (x === ring && y > -ring) return first + y + ring - 1
  if (y === ring) return first + side + ring - 1 - x
  if (x === -ring) return first + 2 * side + ring - 1 - y
  return first + 3 * side + x + ring - 1
}

/** How a window's hours and the kinds shown are laid out inside a cluster. */
export type Geometry = {
  /** The window's hours, each a cell. */
  readonly hours: number
  /** A patch's width in cells, odd, so its first hour is in the middle. */
  readonly side: number
  /** The space between patches, in cells. */
  readonly gap: number
  /** Patches a row. */
  readonly across: number
  /** The cluster's width in cells. */
  readonly width: number
  /** A cell's width in world units. */
  readonly cell: number
}

export function geometry(hours: number, kinds: number): Geometry {
  const side = 2 * Math.ceil((Math.sqrt(hours) - 1) / 2) + 1
  const gap = Math.max(1, Math.round(side * 0.15))
  const across = Math.ceil(Math.sqrt(kinds))
  const width = across * side + (across - 1) * gap
  return {hours, side, gap, across, width, cell: CLUSTER / width}
}

/** The middle of kind `slot`'s patch, in cells from the cluster's middle. */
export function petalAt(shape: Geometry, slot: number, out: [number, number] = [0, 0]): [number, number] {
  const step = shape.side + shape.gap
  const offset = ((shape.across - 1) * step) / 2
  out[0] = (slot % shape.across) * step - offset
  out[1] = Math.floor(slot / shape.across) * step - offset
  return out
}

const spot: [number, number] = [0, 0]
const petal: [number, number] = [0, 0]
const middle: [number, number] = [0, 0]
const start: [number, number] = [0, 0]
const end: [number, number] = [0, 0]

/** The middle of hour `index`'s cell in kind `slot` of the cluster ranked `rank`, in world units. */
export function cellAt(
  shape: Geometry,
  rank: number,
  slot: number,
  index: number,
  out: [number, number] = [0, 0],
): [number, number] {
  clusterAt(rank, middle)
  petalAt(shape, slot, petal)
  spiralAt(index, spot)
  out[0] = middle[0] + (petal[0] + spot[0]) * shape.cell
  out[1] = middle[1] + (petal[1] + spot[1]) * shape.cell
  return out
}

/** What lies at a point of the world: a cluster, and the kind and hour there if any. */
export type Found = {rank: number; slot: number; index: number}

/**
 * The cluster, kind and hour at world point `x`, `y` among `count` clusters:
 * `slot` and `index` are -1 between patches or past the window's last hour.
 * False when no cluster is there.
 */
export function find(shape: Geometry, count: number, x: number, y: number, into: Found) {
  const half = CLUSTER / 2
  for (let rank = 0; rank < count; rank++) {
    clusterAt(rank, middle)
    const dx = x - middle[0]
    const dy = y - middle[1]
    if (Math.abs(dx) > half || Math.abs(dy) > half) continue
    into.rank = rank
    into.slot = -1
    into.index = -1
    const step = shape.side + shape.gap
    const offset = ((shape.across - 1) * step) / 2
    const gx = dx / shape.cell + offset + shape.side / 2
    const gy = dy / shape.cell + offset + shape.side / 2
    const column = Math.floor(gx / step)
    const row = Math.floor(gy / step)
    if (column < 0 || row < 0 || column >= shape.across || row >= shape.across) return true
    if (gx - column * step >= shape.side || gy - row * step >= shape.side) return true
    const ring = (shape.side - 1) / 2
    const index = spiralIndex(Math.floor(gx - column * step) - ring, Math.floor(gy - row * step) - ring)
    if (index >= shape.hours) return true
    into.slot = row * shape.across + column
    into.index = index
    return true
  }
  return false
}

/**
 * Hours `from` up to `to` of a patch as straight runs of cells, each written
 * to `emit` as its corner and size in cells from the patch's middle: a run
 * never turns a corner of the spiral.
 */
export function eachRun(from: number, to: number, emit: (x: number, y: number, w: number, h: number) => void) {
  let index = Math.max(0, from)
  while (index < to) {
    let last = index
    if (index > 0) {
      const ring = Math.ceil((Math.sqrt(index + 1) - 1) / 2)
      const first = (2 * ring - 1) ** 2
      const side = 2 * ring
      last = Math.min(to - 1, first + (Math.floor((index - first) / side) + 1) * side - 1)
    }
    spiralAt(index, start)
    spiralAt(last, end)
    const x = Math.min(start[0], end[0])
    const y = Math.min(start[1], end[1])
    emit(x - 0.5, y - 0.5, Math.abs(start[0] - end[0]) + 1, Math.abs(start[1] - end[1]) + 1)
    index = last + 1
  }
}

/** A card's room in CSS pixels, gap included. */
export const CARD_ROOM: readonly [number, number] = [190, 78]

// The side of the square cell that holds `count` cards in `columns` columns.
const sideFor = (columns: number, count: number) =>
  Math.max(columns * CARD_ROOM[0], Math.ceil(count / columns) * CARD_ROOM[1])

/**
 * The grid the things of one hour fill inside its cell, oldest first, row by
 * row, each place shaped as a card is: the columns that hold `count` cards in
 * the smallest cell, then the rows.
 */
export function columnsFor(count: number) {
  let best = 1
  for (let columns = 2; columns * CARD_ROOM[0] < sideFor(best, count); columns++) {
    if (sideFor(columns, count) < sideFor(best, count)) best = columns
  }
  return best
}

export const rowsFor = (count: number) => Math.max(1, Math.ceil(count / columnsFor(count)))

/** The cell width in CSS pixels at which `count` cards fit their cell. */
export const cardsFrom = (count: number) => sideFor(columnsFor(count), count)

/**
 * How strongly each layer is drawn, 0 to 1, as the cluster grows on screen:
 * clusters as glowing patches at the fleet's scale, their hours as blocks of
 * work once a cluster is a few hundred pixels across, and the things of each
 * hour as points once a cell holds a few.
 */
export type Strengths = {glow: number; blocks: number; dots: number}

const ramp = (value: number, from: number, to: number) => Math.min(1, Math.max(0, (value - from) / (to - from)))

export function strengths(clusterPx: number, cellPx: number, out: Strengths = {glow: 0, blocks: 0, dots: 0}) {
  out.dots = ramp(cellPx, 16, 28)
  out.glow = 1 - ramp(clusterPx, 240, 440)
  out.blocks = ramp(clusterPx, 200, 420) * (1 - 0.65 * out.dots)
  return out
}

/** The zoom's four steps, as the zoom control names them: the last once any hour's cards show. */
export function stepAt(clusterPx: number, cellPx: number, cards: boolean) {
  if (cards) return "Items"
  if (clusterPx < 260) return "Fleet"
  if (cellPx < 16) return "Project"
  return "Hours"
}
