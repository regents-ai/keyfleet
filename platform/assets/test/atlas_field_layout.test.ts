import {describe, expect, it} from "vitest"

import {
  CLUSTER,
  cardsFrom,
  cellAt,
  clusterAt,
  columnsFor,
  eachRun,
  find,
  fleetRadius,
  geometry,
  rowsFor,
  spiralAt,
  spiralIndex,
  strengths,
  type Found,
} from "../js/atlas/field/layout"

// A day, a week, the longest month and a leap year, in hours.
const WINDOWS = [24, 168, 744, 8784]
const KINDS = 9

describe("the square spiral", () => {
  it("gives every hour its own cell, beside the hour before it, ring by ring outward", () => {
    const taken = new Set<string>()
    let last: [number, number] = [0, 0]
    for (let index = 0; index < 10_000; index++) {
      const [x, y] = spiralAt(index)
      expect(spiralIndex(x, y)).toBe(index)
      expect(taken.has(`${x},${y}`)).toBe(false)
      taken.add(`${x},${y}`)
      const ring = Math.max(Math.abs(x), Math.abs(y))
      expect(index).toBeGreaterThanOrEqual(ring === 0 ? 0 : (2 * ring - 1) ** 2)
      expect(index).toBeLessThan((2 * ring + 1) ** 2)
      if (index > 0) expect(Math.abs(x - last[0]) + Math.abs(y - last[1])).toBe(1)
      last = [x, y]
    }
  })

  it("covers a stretch of hours with straight runs holding exactly those hours", () => {
    for (const [from, to] of [
      [0, 1],
      [0, 24],
      [5, 9],
      [24, 48],
      [700, 1440],
      [8760, 8784],
    ]) {
      const covered = new Set<string>()
      eachRun(from, to, (x, y, w, h) => {
        expect(Math.min(w, h)).toBe(1)
        for (let dx = 0; dx < w; dx++) {
          for (let dy = 0; dy < h; dy++) covered.add(`${x + 0.5 + dx},${y + 0.5 + dy}`)
        }
      })
      const expected = new Set<string>()
      for (let index = from; index < to; index++) expected.add(spiralAt(index).join(","))
      expect(covered).toEqual(expected)
    }
  })
})

describe("clusters", () => {
  it("put the busiest in the middle and keep every cluster clear of the others", () => {
    expect(clusterAt(0)).toEqual([0, 0])
    const middles = Array.from({length: 400}, (_, rank) => clusterAt(rank))
    for (let a = 0; a < middles.length; a++) {
      for (let b = a + 1; b < middles.length; b++) {
        const apart = Math.max(Math.abs(middles[a][0] - middles[b][0]), Math.abs(middles[a][1] - middles[b][1]))
        expect(apart).toBeGreaterThanOrEqual(CLUSTER + 40)
      }
    }
    // Busier clusters lie no further out than quieter ones.
    const reach = middles.map(([x, y]) => Math.hypot(x, y))
    for (let rank = 1; rank < reach.length; rank++) expect(reach[rank]).toBeGreaterThan(reach[rank - 1])
    for (const [x, y] of middles) expect(Math.hypot(x, y) + CLUSTER / 2).toBeLessThanOrEqual(fleetRadius(400))
  })

  it("fit each window's hours into patches of the same cluster size", () => {
    for (const hours of WINDOWS) {
      const shape = geometry(hours, KINDS)
      expect(shape.side % 2).toBe(1)
      expect(shape.side ** 2).toBeGreaterThanOrEqual(hours)
      expect((shape.side - 2) ** 2).toBeLessThan(hours)
      expect(shape.across).toBe(3)
      expect(shape.width * shape.cell).toBeCloseTo(CLUSTER)
    }
  })

  it("find each hour of each kind where it is drawn, and nothing between patches", () => {
    const into: Found = {rank: -1, slot: -1, index: -1}
    for (const hours of WINDOWS) {
      const shape = geometry(hours, KINDS)
      for (const rank of [0, 1, 7, 59]) {
        for (let slot = 0; slot < KINDS; slot++) {
          for (const index of [0, 1, Math.floor(hours / 2), hours - 1]) {
            const [x, y] = cellAt(shape, rank, slot, index)
            expect(find(shape, 60, x, y, into)).toBe(true)
            expect(into).toEqual({rank, slot, index})
          }
        }
        // The gap between the first two patches holds no hour.
        const [x, y] = cellAt(shape, rank, 0, 0)
        const gap = x + (shape.side / 2 + shape.gap / 2) * shape.cell
        expect(find(shape, 60, gap, y, into)).toBe(true)
        expect(into.slot).toBe(-1)
      }
      const [x, y] = clusterAt(0)
      expect(find(shape, 1, x + CLUSTER, y, into)).toBe(false)
    }
  })
})

describe("the things of an hour", () => {
  it("fill the smallest cell with room for each, a cell that never shrinks as an hour holds more", () => {
    const side = (columns: number, count: number) => Math.max(columns * 190, Math.ceil(count / columns) * 78)
    for (let count = 1; count <= 200; count++) {
      const columns = columnsFor(count)
      const rows = rowsFor(count)
      expect(columns * rows).toBeGreaterThanOrEqual(count)
      expect(columns * (rows - 1)).toBeLessThan(count)
      expect(cardsFrom(count)).toBe(side(columns, count))
      for (let other = 1; other <= count; other++) expect(cardsFrom(count)).toBeLessThanOrEqual(side(other, count))
      if (count > 1) expect(cardsFrom(count)).toBeGreaterThanOrEqual(cardsFrom(count - 1))
    }
  })
})

describe("the layers as the zoom grows", () => {
  it("hand the field from glows to blocks to points", () => {
    const fleet = strengths(40, 0.4)
    expect(fleet).toEqual({glow: 1, blocks: 0, dots: 0})
    const project = strengths(600, 6)
    expect(project.glow).toBe(0)
    expect(project.blocks).toBe(1)
    expect(project.dots).toBe(0)
    const hours = strengths(6000, 60)
    expect(hours.dots).toBe(1)
    expect(hours.blocks).toBeGreaterThan(0)
    expect(hours.blocks).toBeLessThan(project.blocks)
    let last = strengths(1, 0.01)
    for (let cluster = 2; cluster < 100_000; cluster *= 1.2) {
      const next = strengths(cluster, cluster / 100)
      expect(next.glow).toBeLessThanOrEqual(last.glow)
      expect(next.dots).toBeGreaterThanOrEqual(last.dots)
      last = next
    }
  })
})
