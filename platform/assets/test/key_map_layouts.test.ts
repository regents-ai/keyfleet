import {describe, expect, it, vi} from "vitest"

import {
  axialToPixel,
  hexDistance,
  nearestCopy,
  pixelToAxial,
  SQRT3,
  type Cell,
  type Point,
} from "../js/hooks/key_map/lattice"
import {
  buildMap,
  fibonacciLevelOf,
  fibonacciLevelSupply,
  levelEnd,
  levelStart,
  maxSupply,
  type KeyMapGrid,
  type LayoutKind,
} from "../js/hooks/key_map/layouts"

const areNeighbours = (a: Cell, b: Cell) => hexDistance(a[0] - b[0], a[1] - b[1]) === 1

const fleets: [string, LayoutKind][] = [
  ["fibonacci_syndicate", "fibonacci"],
  ["fibonacci_cascade", "fibonacci"],
  ["fleet_tech_classic", "classic"],
  ["fleet_tech_accelerant", "accelerant"],
  ["regents_club", "regents_club"],
]
const shownCounts = [1, 2, 7, 55, 150, 1_023, 1_024, 1_999, 2_000, 20_000, 46_364, 46_365]
// The Fibonacci fleets have no size, so their map is tried through level 20.
const tested: Record<LayoutKind, number> = {
  fibonacci: levelEnd(20),
  classic: 1_024,
  accelerant: 2_000,
  regents_club: 1_998,
}

// A small deterministic generator, so sampled cells repeat run to run.
function random(seed: number) {
  let state = seed
  return () => {
    state = (Math.imul(state, 1_103_515_245) + 12_345) >>> 0
    return state / 2 ** 32
  }
}

const add = (cell: Cell, period: Cell, times = 1): Cell => [
  cell[0] + period[0] * times,
  cell[1] + period[1] * times,
]

// Every key of one Fibonacci level.
const keysOf = (grid: KeyMapGrid, level: number) =>
  Array.from({length: fibonacciLevelSupply(level)}, (_, index) => levelStart(level) + index).filter(
    key => grid.levelOf(key) === level,
  )

describe("key map layouts", () => {
  // Its build time is checked in the browser, in key_map_performance.spec.ts.
  it("builds the Fibonacci map through level 20", async () => {
    vi.resetModules()
    const cold = await import("../js/hooks/key_map/layouts")
    const grid = cold.buildMap("fibonacci", 46_365)
    expect(grid.valueAt(...grid.home(46_365))).toBe(46_365)
  })

  it("matches the five fleets' supplies", () => {
    expect([1, 2, 3, 4, 5, 6, 7, 8].map(fibonacciLevelSupply)).toEqual([2, 3, 5, 8, 13, 21, 34, 55])
    expect([1, 2, 3, 4, 8].map(levelStart)).toEqual([1, 3, 6, 11, 87])
    expect([1, 2, 7, 20, 21].map(levelEnd)).toEqual([2, 5, 86, 46_365, 75_022])
    expect([1, 2, 3, 5, 6, 87, 141, 142, 46_365, 46_366].map(fibonacciLevelOf)).toEqual([1, 1, 2, 2, 3, 8, 8, 9, 20, 21])
    expect(maxSupply).toEqual({fibonacci: null, classic: 1_024, accelerant: 2_000, regents_club: 1_998})
  })

  it("keeps opening Fibonacci levels past level 20, and never moves a key", async () => {
    vi.resetModules()
    const cold = await import("../js/hooks/key_map/layouts")
    const small = cold.buildMap("fibonacci", 5)
    const homes = [1, 2, 3, 5].map(key => small.home(key))
    const grid = cold.buildMap("fibonacci", levelEnd(22))
    expect([1, 2, 3, 5].map(key => grid.home(key))).toEqual(homes)
    for (const key of [46_366, levelEnd(21), levelEnd(22)]) {
      expect(grid.valueAt(...grid.home(key))).toBe(key)
      expect(grid.levelOf(key)).toBe(fibonacciLevelOf(key))
    }
  })

  it.each(fleets)("round-trips every key of %s through its cell at every size", (_fleet, kind) => {
    for (const shown of shownCounts.filter(count => count <= tested[kind])) {
      const grid = buildMap(kind, shown)
      let mismatches = 0
      for (let key = 1; key <= shown; key++) {
        const home = grid.home(key)
        if (grid.valueAt(...home) !== key) mismatches += 1
        if (grid.valueAt(...add(home, grid.periodA, -3)) !== key) mismatches += 1
        const [x, y] = axialToPixel(...home, 55)
        const [q, r] = pixelToAxial(x, y, 55)
        if (q !== home[0] || r !== home[1]) mismatches += 1
      }
      expect(mismatches, `${kind} at ${shown}`).toBe(0)
    }
  })

  it.each(fleets)("shows each key exactly once per copy of %s", (_fleet, kind) => {
    for (const shown of shownCounts.filter(count => count <= tested[kind])) {
      const grid = buildMap(kind, shown)
      const [aq, ar] = grid.periodA
      const [bq, br] = grid.periodB
      // A fundamental parallelogram of the repeat holds |det| cells.
      const cells = Math.abs(aq * br - ar * bq)
      const seen = new Uint32Array(shown + 1)
      const bLength = Math.abs(br)
      for (let j = 0; j < bLength; j++) {
        for (let i = 0; i < cells / bLength; i++) {
          const value = grid.valueAt(i - Math.floor(j / 2), j)
          if (value > 0) seen[value] += 1
        }
      }
      expect(seen.slice(1).every(count => count === 1), `${kind} at ${shown}`).toBe(true)
    }
  })

  it.each(fleets)("repeats %s consistently under both translations", (_fleet, kind) => {
    const next = random(kind.length)
    for (const shown of shownCounts.filter(count => count <= tested[kind])) {
      const grid = buildMap(kind, shown)
      for (let sample = 0; sample < 4_000; sample++) {
        const cell: Cell = [Math.floor(next() * 20_000) - 10_000, Math.floor(next() * 20_000) - 10_000]
        const value = grid.valueAt(...cell)
        expect(grid.valueAt(...add(cell, grid.periodA))).toBe(value)
        expect(grid.valueAt(...add(cell, grid.periodB))).toBe(value)
        expect(grid.valueAt(...add(add(cell, grid.periodA, -2), grid.periodB, 5))).toBe(value)
      }
    }
  })

  it("lays Level 8 as 28 over 27 on one centre line, nested into each other", () => {
    const grid = buildMap("fibonacci", tested.fibonacci)
    const rows = new Map<number, number[]>()
    for (const key of keysOf(grid, 8)) {
      const [q, r] = grid.home(key)
      rows.set(r, [...(rows.get(r) ?? []), axialToPixel(q, r, 1)[0]])
    }
    const [wide, narrow] = [...rows.entries()].sort(([a], [b]) => a - b).map(([, xs]) => xs)
    expect([wide.length, narrow.length]).toEqual([28, 27])
    const centre = (xs: number[]) => (Math.min(...xs) + Math.max(...xs)) / 2
    expect(centre(narrow)).toBeCloseTo(centre(wide), 9)
    // Each key of the narrow row sits between two keys of the wide row.
    const wideCells = keysOf(grid, 8).slice(0, 28).map(key => grid.home(key))
    for (const key of keysOf(grid, 8).slice(28)) {
      expect(wideCells.filter(cell => areNeighbours(cell, grid.home(key)))).toHaveLength(2)
    }
  })

  it("keeps every Fibonacci row within half a cell of one centre line, later levels in the 28/27 band", () => {
    const grid = buildMap("fibonacci", tested.fibonacci)
    for (let level = 1; level <= 20; level++) {
      const rows = new Map<number, number[]>()
      for (const key of keysOf(grid, level)) {
        const [q, r] = grid.home(key)
        rows.set(r, [...(rows.get(r) ?? []), q + r / 2])
      }
      const lengths = [...rows.values()].map(xs => xs.length)
      if (level < 8) expect(lengths).toEqual([fibonacciLevelSupply(level)])
      else expect(lengths.slice(0, -1).every((length, index) => length === (index % 2 === 0 ? 28 : 27))).toBe(true)
      for (const xs of rows.values()) {
        // Centres in cell widths; a row off the line by half a cell is the nearest lattice position.
        expect(Math.abs((Math.min(...xs) + Math.max(...xs)) / 2)).toBeLessThanOrEqual(0.5)
      }
    }
  })

  it("heads each Fibonacci level in the blank row above its first key", () => {
    const grid = buildMap("fibonacci", tested.fibonacci)
    for (let level = 1; level <= 20; level++) {
      const [q, r] = grid.home(levelStart(level))
      // The row above is odd-r offset: the same column one row up.
      const col = q + Math.floor(r / 2)
      const above = [col - Math.floor((r - 1) / 2), r - 1] as const
      expect(grid.valueAt(...above)).toBe(-level)
    }
  })

  it("makes every consecutive pair of Accelerant keys neighbours", () => {
    const grid = buildMap("accelerant", tested.accelerant)
    for (let key = 2; key <= tested.accelerant; key++) {
      expect(areNeighbours(grid.home(key - 1), grid.home(key)), `keys ${key - 1} and ${key}`).toBe(true)
    }
  })

  it("closes the Classic rhombus at exactly 1,024 keys on 32 × 32", () => {
    const grid = buildMap("classic", tested.classic)
    const cells = new Set(Array.from({length: 1_024}, (_, index) => grid.home(index + 1).join(",")))
    const rhombus = new Set(Array.from({length: 1_024}, (_, index) => `${index % 32},${Math.floor(index / 32)}`))
    expect(cells).toEqual(rhombus)
    for (const shown of [1, 4, 9, 16, 121, 961]) {
      const side = Math.sqrt(shown)
      for (let key = 1; key <= shown; key++) {
        const [q, r] = grid.home(key)
        expect(Math.max(q, r)).toBeLessThan(side)
      }
    }
  })

  it("hits the right key at a tile's centre, near each edge and in the gap", () => {
    const width = 96
    const gap = 6
    const size = width / SQRT3
    for (const kind of ["fibonacci", "classic", "accelerant"] as const) {
      const grid = buildMap(kind, tested[kind])
      for (const key of [1, 2, 55, 1_024, tested[kind]]) {
        const home = grid.home(key)
        const [cx, cy] = axialToPixel(...home, size)
        const hit = (distance: number, angle: number) =>
          grid.valueAt(...pixelToAxial(cx + distance * Math.cos(angle), cy + distance * Math.sin(angle), size))
        expect(hit(0, 0)).toBe(key)
        for (let side = 0; side < 6; side++) {
          // Pointy-top edges face 0°, 60°, … from the centre.
          const angle = (Math.PI / 3) * side
          // Inside the drawn tile near its edge, then in the gap beyond it.
          expect(hit(width / 2 - gap / 2 - 1, angle)).toBe(key)
          expect(hit(width / 2 - 1, angle)).toBe(key)
          const outside = pixelToAxial(cx + (width / 2 + 2) * Math.cos(angle), cy + (width / 2 + 2) * Math.sin(angle), size)
          expect(areNeighbours(outside, home)).toBe(true)
        }
      }
    }
  })

  it("finds the nearest copy of a key as a brute-force search does", () => {
    const next = random(7)
    const size = 96 / SQRT3
    for (const kind of ["fibonacci", "classic", "accelerant"] as const) {
      for (const shown of [3, 1_024, 2_000, 46_365].filter(count => count <= tested[kind])) {
        const grid = buildMap(kind, shown)
        const a = axialToPixel(...grid.periodA, size)
        const b = axialToPixel(...grid.periodB, size)
        for (let sample = 0; sample < 100; sample++) {
          const home = axialToPixel(...grid.home(1 + Math.floor(next() * shown)), size)
          const target: Point = [(next() - 0.5) * 40_000, (next() - 0.5) * 40_000]
          const copy = nearestCopy(home, target, a, b)
          const distance = (point: Point) => Math.hypot(point[0] - target[0], point[1] - target[1])
          // Every copy no farther than the home copy lies within twice that
          // distance of it. The periods meet at 60° to 120°, so such a copy
          // uses at most that distance over (period length × sin 60°) of each.
          const reach = (2 * distance(home)) / Math.sin(Math.PI / 3)
          const spanA = Math.ceil(reach / Math.hypot(...a))
          const spanB = Math.ceil(reach / Math.hypot(...b))
          let best = Infinity
          for (let i = -spanA; i <= spanA; i++) {
            for (let j = -spanB; j <= spanB; j++) {
              best = Math.min(best, distance([home[0] + i * a[0] + j * b[0], home[1] + i * a[1] + j * b[1]]))
            }
          }
          expect(distance(copy)).toBeCloseTo(best, 6)
        }
      }
    }
  })
})
