import {describe, expect, it} from "vitest"

import {
  BOTTOM,
  LANE_FLOATS,
  NOTEBOOK,
  PIECE_FLOATS,
  TOP,
  alternate,
  anchors,
  bounds,
  columns,
  hermite,
  insideOut,
  jitter,
  lanePieces,
  pieces,
  row,
  scales,
  slopeAt,
  type Series,
  type Shape,
  type Stack,
} from "../js/atlas/river/stream"

// A seeded stream of counts with long quiet stretches and sudden bursts, the
// shape that makes an ordinary cubic dip below nothing.
function bursts(n: number, seed: number) {
  const values = new Float64Array(n)
  let state = seed
  for (let i = 0; i < n; i++) {
    state = (state * 1_103_515_245 + 12_345) % 2_147_483_648
    values[i] = state % 5 === 0 ? state % 400 : state % 3 === 0 ? 0 : state % 7
  }
  return values
}

const stackOf = (rows: number[][], series: Series[], bandFlags: number[]): Stack => {
  const n = rows[0].length
  const values = new Float64Array(rows.length * n)
  rows.forEach((row, s) => values.set(row, s * n))
  return {values, n, series, bandFlags}
}

const flat: Shape = {ko: 2, kf: 2, open: 0, lanes: 0, region: 0}

// The shader's bottom and top of a piece's series, from its floats: the same
// sums `vs_band` does on the GPU.
function drawn(data: Float32Array, piece: number, u: number, shape: Shape) {
  const at = piece * PIECE_FLOATS
  const curve = (offset: number) =>
    Math.max(0, hermite(data[at + offset], data[at + offset + 1], data[at + offset + 2], data[at + offset + 3], u))
  const [own, below, chosenBelow, total, chosen, otherBelow] = [4, 8, 12, 16, 20, 24].map(curve)
  const thick = shape.kf * chosen
  const across = thick + (shape.region - thick) * shape.lanes
  const base =
    (1 - shape.open) * (-(shape.ko * (total - chosen) + across) / 2) +
    shape.open * (-across / 2 - shape.ko * otherBelow)
  let lower = base + shape.ko * (below - chosenBelow) + shape.kf * chosenBelow
  const place = data[at + 3]
  if (place === 2) lower += across - thick
  if (place === 1) lower += (across - thick) / 2
  return [lower, lower + (place === 1 ? shape.kf : shape.ko) * own]
}

describe("the Atlas river's stream", () => {
  it("draws each series through its counts without dipping below nothing or overshooting", () => {
    for (const seed of [1, 7, 42, 2026]) {
      const values = bursts(120, seed)
      const n = values.length
      for (let i = 0; i < n - 1; i++) {
        const [p0, p1] = [values[i], values[i + 1]]
        const [m0, m1] = [slopeAt(values, 0, n, i), slopeAt(values, 0, n, i + 1)]
        expect(hermite(p0, p1, m0, m1, 0)).toBeCloseTo(p0, 9)
        expect(hermite(p0, p1, m0, m1, 1)).toBeCloseTo(p1, 9)
        for (let step = 1; step < 16; step++) {
          const value = hermite(p0, p1, m0, m1, step / 16)
          expect(value).toBeGreaterThanOrEqual(Math.min(p0, p1) - 1e-9)
          expect(value).toBeLessThanOrEqual(Math.max(p0, p1) + 1e-9)
        }
      }
    }
  })

  it("is flat at either end and at every peak and trough", () => {
    const values = Float64Array.from([3, 9, 2, 2, 5, 8, 1])
    expect(slopeAt(values, 0, 7, 0)).toBe(0)
    expect(slopeAt(values, 0, 7, 6)).toBe(0)
    expect(slopeAt(values, 0, 7, 1)).toBe(0)
    expect(slopeAt(values, 0, 7, 2)).toBe(0)
    expect(slopeAt(values, 0, 7, 5)).toBe(0)
    expect(slopeAt(values, 0, 7, 4)).toBeGreaterThan(0)
  })

  it("stacks the busiest band in the middle and the rest outwards, neighbours never in one tone", () => {
    for (const count of [1, 2, 5, 13, 61]) {
      const place = insideOut(count)
      expect([...place].sort((a, b) => a - b)).toEqual([...Array(count).keys()])
      expect(place[0]).toBe(Math.floor((count - 1) / 2))
      const rankAt: number[] = []
      place.forEach((at, rank) => (rankAt[at] = rank))
      for (let at = 0; at < count - 1; at++) {
        expect(alternate(rankAt[at])).not.toBe(alternate(rankAt[at + 1]))
      }
      // Further from the middle, quieter.
      for (let rank = 2; rank < count; rank++) {
        expect(Math.abs(place[rank] - place[0])).toBeGreaterThanOrEqual(Math.abs(place[rank - 2] - place[0]))
      }
    }
  })

  it("fills the height with the busiest moment, and gives a chosen band its share once open", () => {
    const shut = {ko: 0, kf: 0}
    scales(400, 0.78, 200, 0, 0, 0, shut)
    expect(shut).toEqual({ko: 2, kf: 2})
    const open = {ko: 0, kf: 0}
    scales(400, 0.78, 200, 50, 180, 1, open)
    expect(open.kf * 50).toBeCloseTo(400 * 0.78)
    expect(open.ko * 180).toBeCloseTo(400 * 0.22)
    const half = {ko: 0, kf: 0}
    scales(400, 0.78, 200, 50, 180, 0.5, half)
    expect(half.kf).toBeCloseTo((2 + open.kf) / 2)
    const empty = {ko: 0, kf: 0}
    scales(400, 0.78, 0, 0, 0, 1, empty)
    expect(empty).toEqual({ko: 400, kf: 400})
  })

  it("stacks the series edge to edge around the middle", () => {
    const series: Series[] = [
      {band: 0, notebook: true, place: 0},
      {band: 0, notebook: false, place: 0},
      {band: 1, notebook: false, place: 0},
      {band: 1, notebook: true, place: 0},
    ]
    const stack = stackOf(
      [
        [1, 2, 3],
        [4, 0, 6],
        [2, 2, 2],
        [0, 5, 1],
      ],
      series,
      [0, 0],
    )
    const out = new Float64Array(8)
    bounds(stack, 0, 0, flat, out)
    for (let s = 0; s < 3; s++) expect(out[2 * s + 1]).toBeCloseTo(out[2 * s + 2])
    expect(out[0]).toBeCloseTo(-out[7])
    expect(out[7] - out[0]).toBeCloseTo(2 * (1 + 4 + 2 + 0))
  })

  it("centres a chosen band and keeps the others on either side of it", () => {
    const series: Series[] = [
      {band: 0, notebook: false, place: 0},
      {band: 1, notebook: false, place: 1},
      {band: 1, notebook: true, place: 1},
      {band: 2, notebook: false, place: 2},
    ]
    const stack = stackOf([[10, 10], [30, 30], [10, 10], [20, 20]], series, [0, 0, 0])
    const shape: Shape = {ko: 1, kf: 5, open: 1, lanes: 0, region: 0}
    const out = new Float64Array(8)
    bounds(stack, 0, 0.5, shape, out)
    expect(out[2]).toBeCloseTo(-(5 * 40) / 2)
    expect(out[5]).toBeCloseTo((5 * 40) / 2)
    expect(out[1]).toBeCloseTo(out[2])
    expect(out[6]).toBeCloseTo(out[5])
    expect(out[1] - out[0]).toBeCloseTo(10)
    expect(out[7] - out[6]).toBeCloseTo(20)
  })

  it("gives the lanes their room around the middle as they open", () => {
    const series: Series[] = [
      {band: 0, notebook: false, place: 0},
      {band: 1, notebook: false, place: 1},
      {band: 2, notebook: false, place: 2},
    ]
    const stack = stackOf([[10, 10], [40, 40], [10, 10]], series, [0, 0, 0])
    const out = new Float64Array(6)
    bounds(stack, 0, 0, {ko: 1, kf: 2, open: 1, lanes: 1, region: 300}, out)
    expect(out[1]).toBeCloseTo(-150)
    expect(out[4]).toBeCloseTo(150)
  })

  it("hands the GPU the same edges the page works out, piece by piece", () => {
    const series: Series[] = [
      {band: 0, notebook: true, place: 0},
      {band: 0, notebook: false, place: 0},
      {band: 1, notebook: false, place: 1},
      {band: 1, notebook: true, place: 1},
      {band: 2, notebook: false, place: 2},
    ]
    const rows = series.map((_, s) => [...bursts(24, s + 3)])
    const stack = stackOf(rows, series, [0, 16, 0])
    const out = new Float32Array(24 * series.length * PIECE_FLOATS)
    const count = pieces(stack, 0.5, 1, out, 10_000, new Float64Array(series.length * 4))
    const edges = new Float64Array(series.length * 2)
    for (const shape of [flat, {ko: 1.5, kf: 3, open: 0.6, lanes: 0.4, region: 220}]) {
      for (let piece = 0; piece < count; piece++) {
        const at = piece * PIECE_FLOATS
        const knot = out[at] - 0.5
        // The series this piece belongs to: its band, and its notebook flag.
        const s = series.findIndex(
          one => one.band === out[at + 1] && one.notebook === ((out[at + 2] & NOTEBOOK) !== 0),
        )
        for (const u of [0, 0.3, 0.7, 1]) {
          bounds(stack, knot, u, shape, edges)
          const [lower, upper] = drawn(out, piece, u, shape)
          expect(lower).toBeCloseTo(edges[2 * s], 3)
          expect(upper).toBeCloseTo(edges[2 * s + 1], 3)
        }
      }
    }
  })

  it("leaves out empty pieces and marks a band's outer edges for the gap between bands", () => {
    const series: Series[] = [
      {band: 0, notebook: true, place: 0},
      {band: 0, notebook: false, place: 0},
      {band: 1, notebook: false, place: 0},
    ]
    const stack = stackOf([[0, 0, 4], [3, 3, 3], [0, 0, 0]], series, [16, 0])
    const out = new Float32Array(10 * PIECE_FLOATS)
    const count = pieces(stack, 0, 24, out, 10, new Float64Array(12))
    // Knots 0-1: only band 0's graph; knots 1-2: both of band 0's series.
    expect(count).toBe(3)
    const flags = [0, 1, 2].map(piece => out[piece * PIECE_FLOATS + 2])
    expect(flags[0]).toBe(16 | BOTTOM | TOP)
    expect(flags[1]).toBe(16 | NOTEBOOK | BOTTOM)
    expect(flags[2]).toBe(16 | TOP)
    expect(out[PIECE_FLOATS]).toBe(24)
    // The graph series sits on the notebooks below it.
    expect(out[2 * PIECE_FLOATS + 9]).toBe(4)
  })

  it("stops at as many pieces as it is given room for", () => {
    const series: Series[] = [{band: 0, notebook: false, place: 0}]
    const stack = stackOf([[1, 1, 1, 1, 1, 1]], series, [0])
    expect(pieces(stack, 0, 1, new Float32Array(3 * PIECE_FLOATS), 3, new Float64Array(4))).toBe(3)
  })

  it("lays a band's kinds out as lanes, the first kind at the top", () => {
    // Two kinds over three knots, the bottom of the band first: tasks, then notebooks.
    const values = Float64Array.from([2, 2, 0, 1, 3, 0])
    const out = new Float32Array(10 * LANE_FLOATS)
    // Two kinds, each with something in both stretches between the three knots.
    const count = lanePieces(values, 2, 3, 1, 0.5, 1, out, 10)
    expect(count).toBe(4)
    // The tasks are the last lane down, the notebooks the first.
    expect(out[1]).toBe(1)
    expect(out[LANE_FLOATS + 1]).toBe(0)
    expect(out[LANE_FLOATS + 2]).toBe(NOTEBOOK)
    // The notebooks sit on the tasks inside the band, which holds both.
    expect(out[LANE_FLOATS + 8]).toBe(2)
    expect(out[LANE_FLOATS + 12]).toBe(3)
  })

  it("puts each band's name where it is thickest in view", () => {
    const series: Series[] = [
      {band: 0, notebook: false, place: 0},
      {band: 0, notebook: true, place: 0},
      {band: 1, notebook: false, place: 0},
    ]
    const stack = stackOf([[1, 5, 2, 9], [1, 1, 6, 0], [0, 0, 0, 0]], series, [0, 0])
    const out = new Int32Array(2)
    const most = new Float64Array(2)
    anchors(stack, 2, 0, 3, out, most)
    expect(out[0]).toBe(3)
    expect(most[0]).toBe(9)
    expect(out[1]).toBe(-1)
    anchors(stack, 2, 0, 2, out, most)
    expect(out[0]).toBe(2)
  })

  it("fits as many cards in an hour as its width holds, and at least one", () => {
    expect(columns(560, 184, 6, 8)).toBe(2)
    expect(columns(1000, 184, 6, 8)).toBe(5)
    expect(columns(100, 184, 6, 8)).toBe(1)
  })

  it("stands each card at its own place when there is room, and in order, apart and inside the hour when not", () => {
    const out = new Float64Array(8)
    // Room for each: every card where it wants to be.
    row([10, 300, 700], 3, 8, 1000, 184, 6, out)
    expect([...out.slice(0, 3)]).toEqual([10, 300, 700])
    // Crowded at the end of the hour: pushed back, in order and apart, the last inside the end.
    row([900, 905, 910], 3, 8, 1000, 184, 6, out)
    expect(out[2]).toBe(1000 - 184)
    expect(out[1]).toBe(out[2] - 190)
    expect(out[0]).toBe(out[1] - 190)
    // Wanting to stand before the start: from the start.
    row([-50, -40], 2, 8, 1000, 184, 6, out)
    expect([...out.slice(0, 2)]).toEqual([8, 198])
    // As many as the hour holds always fit inside it.
    const slots = columns(1000, 184, 6, 8)
    const anywhere = [990, 0, 500, 1000, 20].slice(0, slots)
    row(anywhere.sort((a, b) => a - b), slots, 8, 992, 184, 6, out)
    for (let index = 0; index < slots; index++) {
      expect(out[index]).toBeGreaterThanOrEqual(8)
      expect(out[index] + 184).toBeLessThanOrEqual(992)
      if (index > 0) expect(out[index] - out[index - 1]).toBeGreaterThanOrEqual(190)
    }
  })

  it("places each thing's mark across its lane the same way every time", () => {
    const ids = ["task-1", "nb-z6nx17pe7axf94ma", "", "a much longer id with spaces"]
    for (const id of ids) {
      const at = jitter(id)
      expect(at).toBeGreaterThanOrEqual(-0.5)
      expect(at).toBeLessThan(0.5)
      expect(jitter(id)).toBe(at)
    }
    expect(new Set(ids.map(jitter)).size).toBe(ids.length)
  })
})
