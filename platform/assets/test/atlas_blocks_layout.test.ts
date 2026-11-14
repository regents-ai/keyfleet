import {describe, expect, it} from "vitest"

import {
  GAP,
  HEAD,
  KEEP,
  PAD,
  RADIUS,
  SHOW_AT,
  SHOW_FROM,
  aspect,
  between,
  corner,
  cut,
  fills,
  gutter,
  inner,
  ordered,
  place,
  recency,
  shown,
  squarify,
  type Rect,
} from "../js/atlas/blocks/layout"

const STAGE: Rect = {x: 0, y: 0, w: 960, h: 540}

// A fleet's spread of work: a few busy projects and a long quiet tail.
const tail = (count: number) => Array.from({length: count}, (_, index) => 1000 / (index + 1) ** 1.05)

const area = ({w, h}: Rect) => w * h

function expectToTile(rects: readonly Rect[], weights: readonly number[], room: Rect) {
  const total = weights.reduce((sum, weight) => sum + weight, 0)
  rects.forEach((rect, index) => {
    expect(rect.x).toBeGreaterThanOrEqual(room.x - 1e-6)
    expect(rect.y).toBeGreaterThanOrEqual(room.y - 1e-6)
    expect(rect.x + rect.w).toBeLessThanOrEqual(room.x + room.w + 1e-6)
    expect(rect.y + rect.h).toBeLessThanOrEqual(room.y + room.h + 1e-6)
    expect(area(rect) / area(room)).toBeCloseTo(weights[index] / total, 9)
  })
  for (let a = 0; a < rects.length; a++) {
    for (let b = a + 1; b < rects.length; b++) {
      const [one, two] = [rects[a], rects[b]]
      const across = Math.min(one.x + one.w, two.x + two.w) - Math.max(one.x, two.x)
      const down = Math.min(one.y + one.h, two.y + two.h) - Math.max(one.y, two.y)
      expect(across <= 1e-6 || down <= 1e-6).toBe(true)
    }
  }
}

describe("a squarified layout", () => {
  it("fills its room, each tile as big as its share and none over another", () => {
    for (const count of [1, 2, 7, 60, 180]) {
      const weights = tail(count)
      const {rects, cuts} = squarify(weights, STAGE)
      expect(rects).toHaveLength(count)
      expect(cuts.reduce((sum, each) => sum + each.count, 0)).toBe(count)
      expectToTile(rects, weights, STAGE)
      const covered = rects.reduce((sum, rect) => sum + area(rect), 0)
      expect(covered).toBeCloseTo(area(STAGE), 6)
    }
  })

  it("keeps its tiles near square", () => {
    expect(aspect(squarify(Array(100).fill(1), {x: 0, y: 0, w: 500, h: 500}).rects)).toBeLessThan(1.5)
    expect(aspect(squarify(tail(60), STAGE).rects)).toBeLessThan(3)
  })

  it("lets a tile with no work ride along with no area", () => {
    const {rects} = squarify([5, 0, 3], STAGE)
    expect(area(rects[1])).toBe(0)
    expectToTile([rects[0], rects[2]], [5, 3], STAGE)
    expect(squarify([0, 0], STAGE).rects.every(rect => area(rect) === 0)).toBe(true)
  })

  it("holds its rows under new counts, so tiles grow where they stand", () => {
    const before = tail(30)
    const first = squarify(before, STAGE)
    const after = before.map((weight, index) => weight * (1 + 0.04 * Math.sin(index)))
    const next = squarify(after, STAGE, first.cuts)
    expect(next.cuts).toEqual(first.cuts)
    expectToTile(next.rects, after, STAGE)
    next.rects.forEach((rect, index) => {
      const was = first.rects[index]
      expect(Math.abs(rect.x + rect.w / 2 - (was.x + was.w / 2))).toBeLessThan(40)
      expect(Math.abs(rect.y + rect.h / 2 - (was.y + was.h / 2))).toBeLessThan(40)
    })
  })

  it("cuts afresh once the rows kept would leave a tile far less square", () => {
    const first = squarify([1, 1, 1, 1], STAGE)
    const lopsided = [1000, 1, 1, 1]
    const fresh = squarify(lopsided, STAGE)
    const kept = squarify(lopsided, STAGE, first.cuts)
    const held: Rect[] = []
    place(squarify(lopsided, STAGE).rects.map(area), STAGE, first.cuts, held)
    expect(aspect(held)).toBeGreaterThan(KEEP * aspect(fresh.rects))
    expect(kept).toEqual(fresh)
  })

  it("lays tiles past the rows kept in a fresh layout of what is left", () => {
    const first = squarify(tail(10), STAGE)
    const more = tail(14)
    const {rects, cuts} = squarify(more, STAGE, first.cuts)
    expect(cuts.reduce((sum, each) => sum + each.count, 0)).toBe(14)
    expectToTile(rects, more, STAGE)
  })

  it("cuts the same rows as it lays", () => {
    const areas = squarify(tail(25), STAGE).rects.map(area)
    const out: Rect[] = []
    expect(place(areas, STAGE, cut(areas, STAGE), out)).toEqual(cut(areas, STAGE))
  })
})

describe("the order tiles keep", () => {
  it("keeps the tiles shown where they were, then the new ones busiest first, and drops the gone", () => {
    const weights = new Map([
      ["c", 1],
      ["a", 9],
      ["new-small", 2],
      ["new-big", 50],
      ["new-tie-b", 5],
      ["new-tie-a", 5],
    ])
    expect(ordered(["a", "gone", "c"], weights)).toEqual(["a", "c", "new-big", "new-tie-a", "new-tie-b", "new-small"])
    expect(ordered([], new Map())).toEqual([])
  })
})

describe("opening a tile", () => {
  it("fills the stage at the zoom of its tighter side", () => {
    expect(fills({x: 10, y: 10, w: 480, h: 135}, 960, 540)).toBe(2)
    expect(fills({x: 0, y: 0, w: 96, h: 270}, 960, 540)).toBe(2)
  })

  it("lays its children below a band and inside a margin that are the same on screen at any depth", () => {
    for (const fill of [1, 3, 1e6]) {
      const rect = {x: 7, y: 11, w: 960 / fill, h: 540 / fill}
      const room = inner(rect, fill)
      expect((room.y - rect.y) * fill).toBeCloseTo(HEAD, 6)
      expect((room.x - rect.x) * fill).toBeCloseTo(PAD, 6)
      expect((rect.x + rect.w - room.x - room.w) * fill).toBeCloseTo(PAD, 6)
      expect((rect.y + rect.h - room.y - room.h) * fill).toBeCloseTo(PAD, 6)
    }
    expect(inner({x: 0, y: 0, w: 2, h: 2}, 1)).toMatchObject({w: 0, h: 0})
  })

  it("shows its children only as it grows toward filling the stage", () => {
    expect(shown(SHOW_FROM * 4, 4)).toBe(0)
    expect(shown(1, 4)).toBe(0)
    expect(shown(SHOW_AT * 4, 4)).toBe(1)
    expect(shown(40, 4)).toBe(1)
    let last = 0
    for (let zoom = SHOW_FROM * 4; zoom <= SHOW_AT * 4; zoom += 0.01) {
      const now = shown(zoom, 4)
      expect(now).toBeGreaterThanOrEqual(last)
      last = now
    }
  })
})

describe("how recent", () => {
  it("places work along the window, from its start to its end or now", () => {
    expect(recency(0, 0, 100)).toBe(0)
    expect(recency(25, 0, 100)).toBe(0.25)
    expect(recency(100, 0, 100)).toBe(1)
    expect(recency(-5, 0, 100)).toBe(0)
    expect(recency(500, 0, 100)).toBe(1)
    expect(recency(3, 10, 10)).toBe(1)
  })
})

describe("easing between layouts", () => {
  it("runs from one rect to the other, written in place", () => {
    const from = {x: 0, y: 0, w: 10, h: 20}
    const to = {x: 10, y: 20, w: 30, h: 0}
    const out = {x: 0, y: 0, w: 0, h: 0}
    expect(between(from, to, 0, out)).toEqual(from)
    expect(between(from, to, 0.5, out)).toEqual({x: 5, y: 10, w: 20, h: 10})
    expect(between(from, to, 1, out)).toBe(out)
    expect(out).toEqual(to)
  })
})

describe("a tile's gaps and corners", () => {
  // Every size a tile is drawn at on screen, from a sliver to the whole stage.
  const sides = Array.from({length: 400}, (_, index) => index * 0.25).concat([120, 540, 4000])

  it("keeps the full gap and the full corner once a tile is big enough", () => {
    for (const side of [GAP / 0.15, 60, 540, 4000]) expect(gutter(side)).toBe(GAP)
    for (const side of [60, 540, 4000]) expect(corner(side)).toBe(RADIUS)
  })

  it("narrows both on a small tile, so it never vanishes into its gaps or turns round", () => {
    for (const side of sides) {
      const gap = gutter(side)
      const round = corner(side)
      expect(gap).toBeGreaterThanOrEqual(0)
      expect(gap).toBeLessThanOrEqual(Math.min(GAP, side * 0.15) + 1e-9)
      // What is left once the gap is taken stays most of the tile.
      expect(side - gap).toBeGreaterThanOrEqual(side * 0.85 - 1e-9)
      // The corners take at most a fifth of what is left, so the sides stay straight.
      expect(round).toBeLessThanOrEqual((side - gap) * 0.2 + 1e-9)
      expect(round).toBeLessThanOrEqual(RADIUS)
    }
    expect(gutter(0)).toBe(0)
    expect(corner(0)).toBe(0)
  })

  it("never shrinks as a tile grows", () => {
    for (let index = 1; index < sides.length; index++) {
      expect(gutter(sides[index])).toBeGreaterThanOrEqual(gutter(sides[index - 1]))
      expect(corner(sides[index])).toBeGreaterThanOrEqual(corner(sides[index - 1]))
    }
  })
})
