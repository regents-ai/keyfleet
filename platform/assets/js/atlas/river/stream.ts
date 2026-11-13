/**
 * The river's shapes, as plain numbers: no page, no GPU. Each project is a
 * band of the stream, split into its workspace's work and its notebooks (two
 * series), and the bands are stacked busiest in the middle. Each series runs
 * through its counts, one knot a bucket, as a smooth curve that never
 * overshoots its counts (Steffen's monotone cubic), so a band never dips below
 * nothing between two buckets. A boundary between bands is a sum of those
 * curves, so it is the same kind of curve, and the GPU draws every piece of
 * the stream between two knots from four numbers a curve (`pieces`).
 *
 * A chosen band takes the height: the others keep their order and shrink
 * around it, drawn at another scale (`Shape.ko` for the rest, `Shape.kf` for
 * the chosen band), and the chosen band sits across the middle. Inside it,
 * the lanes of each kind of work open out of the band (`Shape.lanes`) into a
 * region `Shape.region` tall. `bounds` works out on the page exactly what
 * the shader draws, for the pointer and the band names.
 */

/** A series of the stream, bottom to top: one band's graph work or its notebooks. */
export type Series = {
  readonly band: number
  readonly notebook: boolean
  /** Where it stands against the chosen band: below it (or none chosen), in it, or above it. */
  readonly place: 0 | 1 | 2
}

/** The scales the stream is drawn at, in CSS pixels a change, and how far the chosen band and its lanes have opened. */
export type Shape = {
  readonly ko: number
  readonly kf: number
  readonly open: number
  readonly lanes: number
  readonly region: number
}

/** Counts a knot apart, one series after another (`values[series * n + knot]`), and the series bottom to top. */
export type Stack = {
  values: Float64Array
  n: number
  series: readonly Series[]
  /** Each band's own flags: `REST` for the band the rest merge into, `ALT` for every other band from the middle. */
  bandFlags: readonly number[]
}

/** Floats a piece of a band takes: where and what it is, then its own, the stack's and the chosen band's curves. */
export const PIECE_FLOATS = 28
/** Floats a piece of a lane takes: where and which lane, its own curve, the curve below it in the band, and the band's. */
export const LANE_FLOATS = 16
/** Floats a mark takes: when, which lane, how far off its line, how big; its shape and whether it is chosen. */
export const MARK_FLOATS = 8

export const NOTEBOOK = 1
export const BOTTOM = 2
export const TOP = 4
export const REST = 8
export const ALT = 16

/** Steffen's slope at knot `i` of the `n` counts from `offset`, a knot apart; flat at either end. */
export function slopeAt(values: Float64Array, offset: number, n: number, i: number) {
  if (i <= 0 || i >= n - 1) return 0
  const before = values[offset + i] - values[offset + i - 1]
  const after = values[offset + i + 1] - values[offset + i]
  if (before * after <= 0) return 0
  const least = Math.min(Math.abs(before), Math.abs(after), Math.abs(before + after) / 4)
  return 2 * Math.sign(before) * least
}

/** The cubic from `p0` to `p1` with slopes `m0` and `m1`, at `u` from 0 to 1. */
export function hermite(p0: number, p1: number, m0: number, m1: number, u: number) {
  const u2 = u * u
  const u3 = u2 * u
  return (2 * u3 - 3 * u2 + 1) * p0 + (-2 * u3 + 3 * u2) * p1 + (u3 - 2 * u2 + u) * m0 + (u3 - u2) * m1
}

/**
 * Where each of `count` bands, busiest first, stands in the stack from the
 * bottom: the busiest in the middle, the next above it, the next below, and
 * so on outwards.
 */
export function insideOut(count: number) {
  const stack: number[] = []
  for (let rank = 0; rank < count; rank++) {
    if (rank % 2 === 1) stack.push(rank)
    else stack.unshift(rank)
  }
  const place = new Array<number>(count)
  stack.forEach((rank, index) => (place[rank] = index))
  return place
}

/** Whether the band of `rank` wears the second tone: neighbours in the stack never share one. */
export const alternate = (rank: number) => Math.ceil(rank / 2) % 2 === 1

/**
 * The scales the stream is drawn at in a height of `height` pixels: every
 * band on one scale, so the busiest bucket fills it; or, with a band chosen,
 * that band filling `share` of it and the rest the remainder, `open` of the
 * way between the two. Written into `into`, as it is worked out every frame.
 */
export function scales(
  height: number,
  share: number,
  most: number,
  chosen: number,
  others: number,
  open: number,
  into: {ko: number; kf: number},
) {
  const all = height / Math.max(1, most)
  const kf = chosen > 0 ? (height * share) / chosen : all
  const ko = others > 0 ? (height * (1 - share)) / others : all
  into.ko = all + (ko - all) * open
  into.kf = all + (kf - all) * open
}

// Where the stack and its series stand at one point, as the shader works it
// out: the stack's bottom, the chosen band's thickness, and how far each
// series sits past those.
function lowerOf(
  place: number,
  below: number,
  chosenBelow: number,
  total: number,
  chosen: number,
  otherBelow: number,
  shape: Shape,
) {
  const {ko, kf, open, lanes, region} = shape
  const thick = kf * chosen
  const across = thick + (region - thick) * lanes
  const base = (1 - open) * (-(ko * (total - chosen) + across) / 2) + open * (-across / 2 - ko * otherBelow)
  const lower = base + ko * (below - chosenBelow) + kf * chosenBelow
  return place === 2 ? lower + across - thick : place === 1 ? lower + (across - thick) / 2 : lower
}

/**
 * The bottom and top of each series between knots `i` and `i + 1`, `u` of the
 * way along, in pixels up from the middle, into `out[2s]` and `out[2s + 1]`.
 */
export function bounds(stack: Stack, i: number, u: number, shape: Shape, out: Float64Array) {
  const {values, n, series} = stack
  let total = 0
  let chosen = 0
  let otherBelow = 0
  for (let s = 0; s < series.length; s++) {
    const value = valueAt(values, s * n, n, i, u)
    out[2 * s] = value
    total += value
    if (series[s].place === 1) chosen += value
    else if (series[s].place === 0) otherBelow += value
  }
  let below = 0
  let chosenBelow = 0
  for (let s = 0; s < series.length; s++) {
    const own = out[2 * s]
    const {place} = series[s]
    const lower = lowerOf(place, below, chosenBelow, total, chosen, otherBelow, shape)
    out[2 * s] = lower
    out[2 * s + 1] = lower + (place === 1 ? shape.kf : shape.ko) * own
    below += own
    if (place === 1) chosenBelow += own
  }
}

// A series' curve between knots `i` and `i + 1`, `u` of the way along.
function valueAt(values: Float64Array, offset: number, n: number, i: number, u: number) {
  const next = Math.min(i + 1, n - 1)
  return Math.max(
    0,
    hermite(
      values[offset + i],
      values[offset + next],
      slopeAt(values, offset, n, i),
      slopeAt(values, offset, n, next),
      u,
    ),
  )
}

/**
 * Every piece of the stream between two knots, as the GPU draws it, into
 * `out`: at most `max` of them, a knot `step` hours apart from `x0` hours
 * past the layer's base, leaving out the series with nothing in a piece.
 * `scratch` holds four numbers a series. Returns how many were written.
 */
export function pieces(stack: Stack, x0: number, step: number, out: Float32Array, max: number, scratch: Float64Array) {
  const {values, n, series, bandFlags} = stack
  let count = 0
  for (let i = 0; i < n - 1; i++) {
    let t0 = 0, t1 = 0, t2 = 0, t3 = 0
    let f0 = 0, f1 = 0, f2 = 0, f3 = 0
    let o0 = 0, o1 = 0, o2 = 0, o3 = 0
    for (let s = 0; s < series.length; s++) {
      const offset = s * n
      const c = 4 * s
      scratch[c] = values[offset + i]
      scratch[c + 1] = values[offset + i + 1]
      scratch[c + 2] = slopeAt(values, offset, n, i)
      scratch[c + 3] = slopeAt(values, offset, n, i + 1)
      t0 += scratch[c]
      t1 += scratch[c + 1]
      t2 += scratch[c + 2]
      t3 += scratch[c + 3]
      if (series[s].place === 1) {
        f0 += scratch[c]
        f1 += scratch[c + 1]
        f2 += scratch[c + 2]
        f3 += scratch[c + 3]
      } else if (series[s].place === 0) {
        o0 += scratch[c]
        o1 += scratch[c + 1]
        o2 += scratch[c + 2]
        o3 += scratch[c + 3]
      }
    }
    if (t0 === 0 && t1 === 0) continue

    let b0 = 0, b1 = 0, b2 = 0, b3 = 0
    let c0 = 0, c1 = 0, c2 = 0, c3 = 0
    for (let s = 0; s < series.length; s++) {
      const c = 4 * s
      const {band, notebook, place} = series[s]
      const empty = scratch[c] === 0 && scratch[c + 1] === 0
      if (!empty) {
        if (count >= max) return count
        // The band's lowest and highest series with anything in this piece
        // leave the gap between bands.
        let flags = (notebook ? NOTEBOOK : 0) | bandFlags[band]
        if (!hasBelow(series, scratch, s)) flags |= BOTTOM
        if (!hasAbove(series, scratch, s)) flags |= TOP
        const at = count * PIECE_FLOATS
        out[at] = x0 + i * step
        out[at + 1] = band
        out[at + 2] = flags
        out[at + 3] = place
        out[at + 4] = scratch[c]
        out[at + 5] = scratch[c + 1]
        out[at + 6] = scratch[c + 2]
        out[at + 7] = scratch[c + 3]
        out[at + 8] = b0
        out[at + 9] = b1
        out[at + 10] = b2
        out[at + 11] = b3
        out[at + 12] = c0
        out[at + 13] = c1
        out[at + 14] = c2
        out[at + 15] = c3
        out[at + 16] = t0
        out[at + 17] = t1
        out[at + 18] = t2
        out[at + 19] = t3
        out[at + 20] = f0
        out[at + 21] = f1
        out[at + 22] = f2
        out[at + 23] = f3
        out[at + 24] = o0
        out[at + 25] = o1
        out[at + 26] = o2
        out[at + 27] = o3
        count += 1
      }
      b0 += scratch[c]
      b1 += scratch[c + 1]
      b2 += scratch[c + 2]
      b3 += scratch[c + 3]
      if (place === 1) {
        c0 += scratch[c]
        c1 += scratch[c + 1]
        c2 += scratch[c + 2]
        c3 += scratch[c + 3]
      }
    }
  }
  return count
}

// Whether a series of the same band below `s`, or above it, has anything in this piece.
function hasBelow(series: readonly Series[], scratch: Float64Array, s: number) {
  for (let other = s - 1; other >= 0 && series[other].band === series[s].band; other--) {
    if (scratch[4 * other] !== 0 || scratch[4 * other + 1] !== 0) return true
  }
  return false
}

function hasAbove(series: readonly Series[], scratch: Float64Array, s: number) {
  for (let other = s + 1; other < series.length && series[other].band === series[s].band; other++) {
    if (scratch[4 * other] !== 0 || scratch[4 * other + 1] !== 0) return true
  }
  return false
}

/**
 * The chosen band's kinds of work as lanes, into `out`: each piece's own
 * curve, the curve of the kinds stacked below it inside the band, and the
 * band's own, so a lane can open out of the band. `values` holds a row of `n`
 * knots for each kind, bottom of the band first; the bottom kind is the last
 * lane down. Returns how many pieces were written.
 */
export function lanePieces(
  values: Float64Array,
  kinds: number,
  n: number,
  notebook: number,
  x0: number,
  step: number,
  out: Float32Array,
  max: number,
) {
  let count = 0
  for (let i = 0; i < n - 1; i++) {
    let t0 = 0, t1 = 0, t2 = 0, t3 = 0
    for (let k = 0; k < kinds; k++) {
      t0 += values[k * n + i]
      t1 += values[k * n + i + 1]
      t2 += slopeAt(values, k * n, n, i)
      t3 += slopeAt(values, k * n, n, i + 1)
    }
    if (t0 === 0 && t1 === 0) continue
    let b0 = 0, b1 = 0, b2 = 0, b3 = 0
    for (let k = 0; k < kinds; k++) {
      const offset = k * n
      const p0 = values[offset + i]
      const p1 = values[offset + i + 1]
      const m0 = slopeAt(values, offset, n, i)
      const m1 = slopeAt(values, offset, n, i + 1)
      if (p0 !== 0 || p1 !== 0) {
        if (count >= max) return count
        const at = count * LANE_FLOATS
        out[at] = x0 + i * step
        out[at + 1] = kinds - 1 - k
        out[at + 2] = k === notebook ? NOTEBOOK : 0
        out[at + 3] = 0
        out[at + 4] = p0
        out[at + 5] = p1
        out[at + 6] = m0
        out[at + 7] = m1
        out[at + 8] = b0
        out[at + 9] = b1
        out[at + 10] = b2
        out[at + 11] = b3
        out[at + 12] = t0
        out[at + 13] = t1
        out[at + 14] = t2
        out[at + 15] = t3
        count += 1
      }
      b0 += p0
      b1 += p1
      b2 += m0
      b3 += m1
    }
  }
  return count
}

/**
 * The knot from `from` to `to` where each band is thickest, for its name to
 * stand on, into `out` by band (-1 when it has nothing there), with how much
 * it holds there into `most`.
 */
export function anchors(stack: Stack, bands: number, from: number, to: number, out: Int32Array, most: Float64Array) {
  const {values, n, series} = stack
  out.fill(-1, 0, bands)
  most.fill(0, 0, bands)
  const [first, last] = [Math.max(0, from), Math.min(n - 1, to)]
  for (let i = first; i <= last; i++) {
    let s = 0
    while (s < series.length) {
      const band = series[s].band
      let sum = 0
      for (; s < series.length && series[s].band === band; s++) sum += values[s * n + i]
      if (sum > most[band]) {
        most[band] = sum
        out[band] = i
      }
    }
  }
}

/** How many cards stand side by side in an hour `zoom` pixels wide. */
export const columns = (zoom: number, width: number, gap: number, pad: number) =>
  Math.max(1, Math.floor((zoom - 2 * pad + gap) / (width + gap)))

/**
 * Where `count` cards `width` wide stand in a row from `start` to `end`, into
 * `out`: in order, `gap` apart, each as near its own place in `at` as the
 * others let it. Cards that cannot all fit run on past `end`.
 */
export function row(
  at: ArrayLike<number>,
  count: number,
  start: number,
  end: number,
  width: number,
  gap: number,
  out: Float64Array,
) {
  const step = width + gap
  let next = start
  for (let index = 0; index < count; index++) {
    out[index] = Math.max(at[index], next)
    next = out[index] + step
  }
  let last = end - width
  for (let index = count - 1; index >= 0; index--) {
    out[index] = Math.max(start + index * step, Math.min(out[index], last))
    last = out[index] - step
  }
}

/** Where a thing's mark sits across its lane, from -0.5 to 0.5, the same each time it is drawn. */
export function jitter(id: string) {
  let hash = 0x811c9dc5
  for (let index = 0; index < id.length; index++) {
    hash ^= id.charCodeAt(index)
    hash = Math.imul(hash, 0x01000193)
  }
  return (hash >>> 0) / 0x1_0000_0000 - 0.5
}
