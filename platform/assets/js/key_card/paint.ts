/**
 * Every layer of a key's card, painted once per key on a 2D canvas and handed to the GPU as bytes.
 *
 * Card layers are 640 x 896 px: 512 px per card unit, and the card is 1.25 x 1.75 units. Data
 * layers (height, metal, foil) are packed by hand so no channel is premultiplied.
 */

import {
  BLADES,
  CROWN_BLOCKS,
  CROWNS,
  EMBLEMS,
  EXTERIORS,
  GEMS,
  METALS,
  SHAFT,
  SHELLS,
  UPRIGHT,
  emblemSvg,
  keySvg,
  neck,
  type Corner,
  type Crest,
  type Exterior,
  type Metal,
  type Motif,
  type Ornament,
  type Shell,
  type Side,
} from "./looks"
import {indexOf, type Key} from "./traits"

type Vec2 = readonly [number, number]
type Ctx = CanvasRenderingContext2D
type Field = Float32Array<ArrayBuffer>

export const TW = 640
export const TH = 896
const PXU = 512
const HX = 0.625
const HY = 0.875
const X = (x: number): number => (x + HX) * PXU
const Y = (y: number): number => (y + HY) * PXU
const U = (v: number): number => v * PXU
export const KW = 680
export const KH = 260

/** The card's lettering, the same two faces as the site's own pages. */
export const DISPLAY_FONT = "'Bricolage Grotesque Variable'"
export const LABEL_FONT = "'IBM Plex Mono'"

const clamp = (v: number, a: number, b: number): number => Math.min(b, Math.max(a, v))

function hexRgb(hex: string): [number, number, number] {
  const n = parseInt(hex.replace("#", ""), 16)
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255]
}
function lum(hex: string): number {
  const [r, g, b] = hexRgb(hex).map(c => {
    const v = c / 255
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4
  })
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}
const rgbHex = (c: readonly number[]): string =>
  "#" + c.map(v => clamp(Math.round(v), 0, 255).toString(16).padStart(2, "0")).join("")
function mix(a: string, b: string, t: number): string {
  const A = hexRgb(a)
  const B = hexRgb(b)
  return rgbHex(A.map((v, i) => v + (B[i] - v) * t))
}
/** A small seeded random source, so the same key always paints the same card. */
function prng(n: number): () => number {
  let a = n >>> 0
  return () => {
    a = (a + 0x6d2b79f5) | 0
    let t = Math.imul(a ^ (a >>> 15), 1 | a)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function canvas(w = TW, h = TH): HTMLCanvasElement {
  const c = document.createElement("canvas")
  c.width = w
  c.height = h
  return c
}
const g2d = (c: HTMLCanvasElement): Ctx => c.getContext("2d", {willReadFrequently: true})!

/** What `draw` paints, as coverage from 0 to 1 per pixel. */
function mask(draw: (g: Ctx) => void, w = TW, h = TH): Field {
  const c = canvas(w, h)
  const g = g2d(c)
  g.fillStyle = g.strokeStyle = "#fff"
  g.lineCap = g.lineJoin = "round"
  draw(g)
  const d = g.getImageData(0, 0, w, h).data
  const m = new Float32Array(w * h)
  for (let i = 0; i < m.length; i++) m[i] = d[i * 4 + 3] / 255
  return m
}
/** A box blur run `passes` times, which comes close to a Gaussian. */
function blur(src: Field, w: number, h: number, radius: number, passes = 3): Field {
  const r = Math.max(1, Math.round(radius))
  const a = Float32Array.from(src)
  const b = new Float32Array(src.length)
  const k = 1 / (2 * r + 1)
  for (let p = 0; p < passes; p++) {
    for (let y = 0; y < h; y++) {
      const o = y * w
      let s = a[o] * (r + 1)
      for (let i = 0; i < r; i++) s += a[o + Math.min(i, w - 1)]
      for (let x = 0; x < w; x++) {
        s += a[o + Math.min(x + r, w - 1)] - a[o + Math.max(x - r - 1, 0)]
        b[o + x] = s * k
      }
    }
    for (let x = 0; x < w; x++) {
      let s = b[x] * (r + 1)
      for (let i = 0; i < r; i++) s += b[Math.min(i, h - 1) * w + x]
      for (let y = 0; y < h; y++) {
        s += b[Math.min(y + r, h - 1) * w + x] - b[Math.max(y - r - 1, 0) * w + x]
        a[y * w + x] = s * k
      }
    }
  }
  return a
}
const sstep = (a: number, b: number, x: number): number => {
  const t = clamp((x - a) / (b - a), 0, 1)
  return t * t * (3 - 2 * t)
}
const mapF = (f: Field, fn: (x: number, i: number) => number): Field => {
  const o = new Float32Array(f.length)
  for (let i = 0; i < f.length; i++) o[i] = fn(f[i], i)
  return o
}
const setLevel = (T: Field, m: Field, v: number): void => {
  for (let i = 0; i < T.length; i++) T[i] += (v - T[i]) * m[i]
}

/** Value noise painted small and scaled up: soft, cheap texture for shells and skies. */
function noiseCanvas(w: number, h: number, cells: Vec2, seed: number): HTMLCanvasElement {
  const r = prng(seed)
  const c = canvas(cells[0], cells[1])
  const g = g2d(c)
  const im = g.createImageData(cells[0], cells[1])
  for (let i = 0; i < cells[0] * cells[1]; i++) {
    const v = r() * 255
    im.data.set([v, v, v, 255], i * 4)
  }
  g.putImageData(im, 0, 0)
  const out = canvas(w, h)
  const o = g2d(out)
  o.imageSmoothingQuality = "high"
  o.drawImage(c, 0, 0, w, h)
  return out
}
async function svgCanvas(svg: string, w: number, h: number): Promise<HTMLCanvasElement> {
  const img = new Image()
  img.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg)
  await img.decode()
  const c = canvas(w, h)
  g2d(c).drawImage(img, 0, 0, w, h)
  return c
}
function fontsReady(): Promise<unknown> {
  return Promise.all([`700 40px ${DISPLAY_FONT}`, `600 20px ${LABEL_FONT}`].map(f => document.fonts.load(f))).then(
    () => document.fonts.ready,
  )
}
/** Text centred on x, with `track` px between letters. */
function spaced(g: Ctx, text: string, x: number, y: number, track: number): void {
  const chars = [...text]
  const ws = chars.map(ch => g.measureText(ch).width)
  const total = ws.reduce((a, b) => a + b, 0) + track * (chars.length - 1)
  let at = x - total / 2
  chars.forEach((ch, i) => {
    g.fillText(ch, at, y)
    at += ws[i] + track
  })
}

/* ---------------- the card outline ---------------- */
function cardPath(g: Ctx, inset: number, corner: Corner): void {
  const x0 = X(-HX + inset)
  const x1 = X(HX - inset)
  const y0 = Y(-HY + inset)
  const y1 = Y(HY - inset)
  g.beginPath()
  if (corner === "chamfer") {
    const c = U(Math.max(0.02, 0.085 - inset * 0.45))
    g.moveTo(x0 + c, y0)
    g.lineTo(x1 - c, y0)
    g.lineTo(x1, y0 + c)
    g.lineTo(x1, y1 - c)
    g.lineTo(x1 - c, y1)
    g.lineTo(x0 + c, y1)
    g.lineTo(x0, y1 - c)
    g.lineTo(x0, y0 + c)
  } else if (corner === "notch") {
    const n = U(Math.max(0.018, 0.075 - inset * 0.5))
    g.moveTo(x0 + n, y0)
    g.lineTo(x1 - n, y0)
    g.arc(x1, y0, n, Math.PI, Math.PI / 2, true)
    g.lineTo(x1, y1 - n)
    g.arc(x1, y1, n, -Math.PI / 2, Math.PI, true)
    g.lineTo(x0 + n, y1)
    g.arc(x0, y1, n, 0, -Math.PI / 2, true)
    g.lineTo(x0, y0 + n)
    g.arc(x0, y0, n, Math.PI / 2, 0, true)
  } else {
    g.roundRect(x0, y0, x1 - x0, y1 - y0, U(Math.max(0.012, 0.062 - inset)))
  }
  g.closePath()
}

type OutlinePoint = {x: number; y: number; tx: number; ty: number; nx: number; ny: number; s: number}
type OutlinePart = {len: number; at: (t: number) => Vec2}

/**
 * The same outline as a list of evenly spaced points, each with its direction along the edge
 * (clockwise) and the direction pointing into the card, for laying patterns along the rim.
 */
function outlinePoints(inset: number, corner: Corner, step: number): OutlinePoint[] {
  const x0 = X(-HX + inset)
  const x1 = X(HX - inset)
  const y0 = Y(-HY + inset)
  const y1 = Y(HY - inset)
  const parts: OutlinePart[] = []
  const line = (ax: number, ay: number, bx: number, by: number): void => {
    parts.push({len: Math.hypot(bx - ax, by - ay), at: t => [ax + (bx - ax) * t, ay + (by - ay) * t]})
  }
  const arc = (cx: number, cy: number, r: number, a0: number, a1: number): void => {
    parts.push({
      len: Math.abs(a1 - a0) * r,
      at: t => {
        const a = a0 + (a1 - a0) * t
        return [cx + r * Math.cos(a), cy + r * Math.sin(a)]
      },
    })
  }
  const H = Math.PI / 2
  if (corner === "chamfer") {
    const c = U(Math.max(0.02, 0.085 - inset * 0.45))
    const pts: Vec2[] = [
      [x0 + c, y0], [x1 - c, y0], [x1, y0 + c], [x1, y1 - c], [x1 - c, y1], [x0 + c, y1], [x0, y1 - c], [x0, y0 + c], [x0 + c, y0],
    ]
    for (let i = 0; i < 8; i++) line(pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1])
  } else if (corner === "notch") {
    const n = U(Math.max(0.018, 0.075 - inset * 0.5))
    line(x0 + n, y0, x1 - n, y0)
    arc(x1, y0, n, Math.PI, H)
    line(x1, y0 + n, x1, y1 - n)
    arc(x1, y1, n, -H, -Math.PI)
    line(x1 - n, y1, x0 + n, y1)
    arc(x0, y1, n, 0, -H)
    line(x0, y1 - n, x0, y0 + n)
    arc(x0, y0, n, H, 0)
  } else {
    const r = U(Math.max(0.012, 0.062 - inset))
    line(x0 + r, y0, x1 - r, y0)
    arc(x1 - r, y0 + r, r, -H, 0)
    line(x1, y0 + r, x1, y1 - r)
    arc(x1 - r, y1 - r, r, 0, H)
    line(x1 - r, y1, x0 + r, y1)
    arc(x0 + r, y1 - r, r, H, Math.PI)
    line(x0, y1 - r, x0, y0 + r)
    arc(x0 + r, y0 + r, r, Math.PI, Math.PI + H)
  }
  const total = parts.reduce((s, p) => s + p.len, 0)
  const n = Math.round(total / step)
  const out: OutlinePoint[] = []
  let pi = 0
  let before = 0
  for (let i = 0; i < n; i++) {
    const d = (i * total) / n
    while (pi < parts.length - 1 && d > before + parts[pi].len) before += parts[pi++].len
    const p = parts[pi]
    const t = clamp((d - before) / p.len, 0, 1)
    const [x, y] = p.at(t)
    const e = 1e-3
    const [xa, ya] = p.at(Math.max(t - e, 0))
    const [xb, yb] = p.at(Math.min(t + e, 1))
    const l = Math.hypot(xb - xa, yb - ya) || 1
    const tx = (xb - xa) / l
    const ty = (yb - ya) / l
    out.push({x, y, tx, ty, nx: -ty, ny: tx, s: d})
  }
  return out
}

/* ---------------- the key ---------------- */
type KeyMasks = {whole: HTMLCanvasElement; emblem: HTMLCanvasElement}

/** The handle: the emblem turned upright for the slot's side, and its neck to the shaft. */
async function handleShapes(name: string, side: Side): Promise<string[]> {
  const turned = `<g transform="rotate(${UPRIGHT[side]} 64 65)">${EMBLEMS[name]().join("")}</g>`
  const alone = g2d(await svgCanvas(keySvg(turned, KW, KH), KW, KH)).getImageData(0, 116, KW, 29).data
  let reach = 0
  for (let i = 0; i < alone.length; i += 4) if (alone[i] > 128) reach = Math.max(reach, ((i / 4) % KW) / 2)
  return [turned, neck(reach)]
}
async function keyMasks(key: Key): Promise<KeyMasks> {
  const ext = EXTERIORS[key.exterior]
  const shapes = [...(await handleShapes(key.emblem, ext.side)), ...SHAFT, ...BLADES[ext.blade]()]
  const whole = await svgCanvas(keySvg(shapes.join(""), KW, KH), KW, KH)
  const emblem = await svgCanvas(emblemSvg(EMBLEMS[key.emblem]().join("")), 256, 256)
  return {whole, emblem}
}

/** Where the key rests: the handle sits on the rim of the slot's side and the blade points inward. */
export type Placement = {axis: Vec2; perp: Vec2; origin: Vec2; center: Vec2; crest: Vec2; title: number}

function placement(ext: Exterior): Placement {
  const axis: Vec2 = ({left: [1, 0], right: [-1, 0], top: [0, 1], bottom: [0, -1]} as const)[ext.side]
  const perp: Vec2 = [-axis[1], axis[0]]
  const handleC = 64 / 340
  const tip = 324 / 340
  const handle: Vec2 =
    ext.side === "left" ? [-HX + 0.02, 0.4] : ext.side === "right" ? [HX - 0.02, 0.4] : ext.side === "top" ? [0, -HY + 0.02] : [0, HY - 0.02]
  const origin: Vec2 = [handle[0] - axis[0] * handleC, handle[1] - axis[1] * handleC]
  const mid = (handleC + tip) / 2
  const center: Vec2 = [origin[0] + axis[0] * mid, origin[1] + axis[1] * mid]
  const crest: Vec2 = ext.side === "top" ? [0, 0.38] : ext.side === "bottom" ? [0, -0.38] : [0, -0.27]
  const title = ext.side === "top" ? 0.73 : -0.73
  return {axis, perp, origin, center, crest, title}
}
function keyTransform(g: Ctx, pl: Placement): void {
  const s = PXU / KW
  const [ax, ay] = pl.axis
  const [px, py] = pl.perp
  g.setTransform(ax * s, ay * s, px * s, py * s, X(pl.origin[0]) - px * (KH / 2) * s, Y(pl.origin[1]) - py * (KH / 2) * s)
}

export type Layers = {w: number; h: number; alb: Uint8Array<ArrayBuffer>; aux: Uint8Array<ArrayBuffer>}
export type CardLayers = Layers & {mat: Uint8Array<ArrayBuffer>; pl: Placement}

/** The key texture: albedo tint (the metal colour is applied by the light), height, an engraved border, and two soft shadows. */
function buildKey(m: Metal, masks: KeyMasks, seedN: number): Layers {
  const rnd = prng(seedN ^ 0x4b3)
  const N = KW * KH
  const A = mask(g => g.drawImage(masks.whole, 0, 0), KW, KH)
  const e = blur(A, KW, KH, 7, 2)
  const inner = mapF(e, x => sstep(0.86, 0.97, x))
  const H = mapF(A, (a, i) => a * (0.35 + 0.65 * Math.pow(sstep(0.05, 0.75, e[i]), 0.8)))
  const border = mapF(inner, (x, i) => A[i] * sstep(0.2, 0.45, x) * (1 - sstep(0.55, 0.8, x)))
  for (let i = 0; i < N; i++) H[i] -= border[i] * 0.12
  const tint = canvas(KW, KH)
  const t = g2d(tint)
  t.fillStyle = m.fx === "jade" ? "#e8f3ec" : "#ffffff"
  t.fillRect(0, 0, KW, KH)
  if (m.fx === "brushed") {
    for (let y = 0; y < KH; y += 2) {
      t.fillStyle = `rgba(0,0,0,${(rnd() * 0.09).toFixed(3)})`
      t.fillRect(0, y, KW, 1)
    }
  }
  if (m.fx === "damascus") {
    t.lineWidth = 5
    for (let k = -6; k < 30; k++) {
      t.strokeStyle = k % 2 ? "rgba(40,44,50,.45)" : "rgba(255,255,255,.35)"
      t.beginPath()
      for (let x = 0; x <= KW; x += 8) {
        const y = k * 14 + 18 * Math.sin(x / 55 + k * 0.5) + 8 * Math.sin(x / 17)
        if (x) t.lineTo(x, y)
        else t.moveTo(x, y)
      }
      t.stroke()
    }
  }
  if (m.fx === "meteor") {
    t.lineWidth = 1.4
    t.strokeStyle = "rgba(40,42,46,.4)"
    for (let i = 0; i < 90; i++) {
      const a = [0, 1.05, 2.1][i % 3]
      const x = rnd() * KW
      const y = rnd() * KH
      const l = 20 + rnd() * 70
      t.beginPath()
      t.moveTo(x - Math.cos(a) * l, y - Math.sin(a) * l)
      t.lineTo(x + Math.cos(a) * l, y + Math.sin(a) * l)
      t.stroke()
    }
  }
  if (m.fx === "opal") {
    for (let i = 0; i < 26; i++) {
      const x = rnd() * KW
      const y = rnd() * KH
      const r = 18 + rnd() * 50
      const gr = t.createRadialGradient(x, y, 0, x, y, r)
      gr.addColorStop(0, ["#ffc2e0", "#b8fff0", "#fff0a8", "#c8d4ff"][i % 4])
      gr.addColorStop(1, "rgba(255,255,255,0)")
      t.fillStyle = gr
      t.fillRect(0, 0, KW, KH)
    }
  }
  if (m.fx === "jade") {
    t.lineWidth = 2
    for (let i = 0; i < 14; i++) {
      t.strokeStyle = `rgba(${i % 2 ? "255,255,255,.35" : "20,60,40,.35"})`
      t.beginPath()
      let x = rnd() * KW
      let y = rnd() * KH
      t.moveTo(x, y)
      for (let k = 0; k < 6; k++) {
        x += (rnd() - 0.3) * 90
        y += (rnd() - 0.5) * 60
        t.lineTo(x, y)
      }
      t.stroke()
    }
  }
  const td = t.getImageData(0, 0, KW, KH).data
  const shadowNear = blur(A, KW, KH, 3)
  const shadowFar = blur(A, KW, KH, 11)
  const alb = new Uint8Array(N * 4)
  const aux = new Uint8Array(N * 4)
  for (let i = 0; i < N; i++) {
    const a = A[i]
    alb[i * 4] = td[i * 4] * a
    alb[i * 4 + 1] = td[i * 4 + 1] * a
    alb[i * 4 + 2] = td[i * 4 + 2] * a
    alb[i * 4 + 3] = a * 255
    aux[i * 4] = clamp(H[i], 0, 1) * 255
    aux[i * 4 + 1] = border[i] * 255
    aux[i * 4 + 2] = shadowNear[i] * 255
    aux[i * 4 + 3] = shadowFar[i] * 255
  }
  return {w: KW, h: KH, alb, aux}
}

/* ---------------- card pieces ---------------- */
function crestPath(g: Ctx, shape: Crest, r: number): void {
  const R0 = U(r)
  g.beginPath()
  switch (shape) {
    case "circle":
      g.arc(0, 0, R0, 0, Math.PI * 2)
      break
    case "diamond":
      g.moveTo(0, -R0 * 1.12)
      g.lineTo(R0 * 1.12, 0)
      g.lineTo(0, R0 * 1.12)
      g.lineTo(-R0 * 1.12, 0)
      break
    case "hex":
      for (let i = 0; i < 6; i++) {
        const a = Math.PI / 6 + (i * Math.PI) / 3
        if (i) g.lineTo(R0 * Math.cos(a), R0 * Math.sin(a))
        else g.moveTo(R0 * Math.cos(a), R0 * Math.sin(a))
      }
      break
    case "shield":
      g.moveTo(-R0 * 0.9, -R0 * 0.95)
      g.lineTo(R0 * 0.9, -R0 * 0.95)
      g.lineTo(R0 * 0.9, R0 * 0.1)
      g.quadraticCurveTo(R0 * 0.85, R0 * 0.8, 0, R0 * 1.1)
      g.quadraticCurveTo(-R0 * 0.85, R0 * 0.8, -R0 * 0.9, R0 * 0.1)
      break
    case "arch":
      g.moveTo(-R0 * 0.85, R0)
      g.lineTo(-R0 * 0.85, -R0 * 0.1)
      g.arc(0, -R0 * 0.1, R0 * 0.85, Math.PI, 0)
      g.lineTo(R0 * 0.85, R0)
      break
  }
  g.closePath()
}
/** Drawn in a corner frame: origin at the card corner, x and y run inward, units are px. */
function cornerOrnament(g: Ctx, style: Ornament): void {
  const u = U(1)
  switch (style) {
    case "brackets":
      g.fillRect(0.075 * u, 0.075 * u, 0.15 * u, 0.012 * u)
      g.fillRect(0.075 * u, 0.075 * u, 0.012 * u, 0.15 * u)
      g.fillRect(0.062 * u, 0.062 * u, 0.024 * u, 0.024 * u)
      g.lineWidth = 2
      g.beginPath()
      g.moveTo(0.1 * u, 0.1 * u)
      g.lineTo(0.17 * u, 0.17 * u)
      g.stroke()
      break
    case "studs":
      for (const [x, y, r] of [[0.1, 0.1, 0.02], [0.16, 0.09, 0.012], [0.09, 0.16, 0.012], [0.21, 0.09, 0.008], [0.09, 0.21, 0.008]]) {
        g.beginPath()
        g.arc(x * u, y * u, r * u, 0, Math.PI * 2)
        g.fill()
      }
      g.lineWidth = 2.5
      g.beginPath()
      g.arc(0.1 * u, 0.1 * u, 0.032 * u, 0, Math.PI * 2)
      g.stroke()
      break
    case "fans":
      g.lineWidth = 2.4
      for (let k = 0; k < 7; k++) {
        const a = ((k / 6) * Math.PI) / 2
        g.beginPath()
        g.moveTo(0.07 * u, 0.07 * u)
        g.lineTo((0.07 + 0.15 * Math.cos(a)) * u, (0.07 + 0.15 * Math.sin(a)) * u)
        g.stroke()
      }
      for (const r of [0.15, 0.19]) {
        g.beginPath()
        g.arc(0.07 * u, 0.07 * u, r * u, 0, Math.PI / 2)
        g.stroke()
      }
      break
    case "leaves":
      g.lineWidth = 2.4
      g.beginPath()
      g.moveTo(0.07 * u, 0.24 * u)
      g.quadraticCurveTo(0.08 * u, 0.09 * u, 0.24 * u, 0.07 * u)
      g.stroke()
      for (const [x, y, a] of [[0.09, 0.18, -1.1], [0.12, 0.11, -0.6], [0.18, 0.085, -0.2]]) {
        g.save()
        g.translate(x * u, y * u)
        g.rotate(a)
        g.beginPath()
        g.ellipse(0, -0.022 * u, 0.012 * u, 0.026 * u, 0, 0, Math.PI * 2)
        g.fill()
        g.restore()
      }
      break
    case "stars": {
      const star = (x: number, y: number, r: number): void => {
        g.beginPath()
        for (let i = 0; i < 8; i++) {
          const a = (i * Math.PI) / 4
          const rr = i % 2 ? r * 0.32 : r
          g.lineTo(x + rr * Math.cos(a), y + rr * Math.sin(a))
        }
        g.closePath()
        g.fill()
      }
      star(0.11 * u, 0.11 * u, 0.045 * u)
      star(0.19 * u, 0.085 * u, 0.018 * u)
      star(0.085 * u, 0.19 * u, 0.018 * u)
      break
    }
    case "scrolls":
      g.lineWidth = 2.6
      for (const [sx, sy] of [[1, 0], [0, 1]]) {
        g.beginPath()
        for (let i = 0; i <= 40; i++) {
          const t = i / 40
          const a = t * Math.PI * 3.2
          const r = (0.05 - t * 0.038) * u
          const bx = (0.07 + sx * 0.09) * u
          const by = (0.07 + sy * 0.09) * u
          const x = bx + r * Math.cos(a + (sx ? 0 : Math.PI / 2))
          const y = by + r * Math.sin(a + (sx ? 0 : Math.PI / 2))
          if (i) g.lineTo(x, y)
          else g.moveTo(x, y)
        }
        g.stroke()
      }
      g.beginPath()
      g.arc(0.07 * u, 0.07 * u, 0.018 * u, 0, Math.PI * 2)
      g.fill()
      break
  }
}
/**
 * How a card is dressed beyond its traits. A Regents Club card has black enamel, gold lettering and
 * "CLUB PASS" in its bottom-right corner; every other card is standard. Every top line starts with the
 * card's type, so the type printed on the card decides its look.
 */
type Look = "standard" | "regentsClub"
const lookOf = (topLine: string): Look => (topLine.startsWith("REGENTS CLUB") ? "regentsClub" : "standard")

/**
 * The bottom-left corner holds the Regents crown, so ornaments go in the other three; a Regents Club card
 * keeps the bottom-right for its "CLUB PASS" mark.
 */
const ORNAMENT_CORNERS: Readonly<Record<Look, readonly (readonly [number, number, number, number])[]>> = {
  standard: [[0, 0, 1, 1], [TW, 0, -1, 1], [TW, TH, -1, -1]],
  regentsClub: [[0, 0, 1, 1], [TW, 0, -1, 1]],
}
function eachCorner(g: Ctx, look: Look, draw: () => void): void {
  for (const [x, y, sx, sy] of ORNAMENT_CORNERS[look]) {
    g.setTransform(sx, 0, 0, sy, x, y)
    draw()
  }
  g.setTransform(1, 0, 0, 1, 0, 0)
}
/** The engraving across the face. Lines are stroked in white; the caller clips them to the open face. */
function motif(g: Ctx, name: Motif, pl: Placement, rnd: () => number): void {
  const u = U(1)
  const hx = X(pl.center[0])
  const hy = Y(pl.center[1])
  const cx = X(pl.crest[0])
  const cy = Y(pl.crest[1])
  g.lineWidth = 2.2
  const line = (pts: readonly Vec2[]): void => {
    g.beginPath()
    pts.forEach(([x, y], i) => (i ? g.lineTo(x, y) : g.moveTo(x, y)))
    g.stroke()
  }
  const circle = (x: number, y: number, r: number): void => {
    g.beginPath()
    g.arc(x, y, r, 0, Math.PI * 2)
    g.stroke()
  }
  switch (name) {
    case "waves":
      for (let y = -10; y < TH + 20; y += 17) line(Array.from({length: 70}, (_, i): Vec2 => [i * 10, y + 5 * Math.sin((i * 10) / 26 + y * 0.07)]))
      break
    case "ruled":
      for (let y = 14; y < TH; y += 21) line([[0, y], [TW, y]])
      g.lineWidth = 3
      line([[0.2 * u, 0], [0.2 * u, TH]])
      line([[0.2 * u + 7, 0], [0.2 * u + 7, TH]])
      break
    case "rings":
      for (let r = 26; r < 1000; r += 19) circle(hx, hy, r)
      break
    case "chevrons":
      for (let y = -30; y < TH + 30; y += 25) line(Array.from({length: 16}, (_, i): Vec2 => [i * 44, y + (i % 2 ? 16 : 0)]))
      break
    case "circuit":
      g.lineWidth = 2.4
      for (let i = 0; i < 46; i++) {
        let x = Math.round(rnd() * 32) * 20
        let y = Math.round(rnd() * 45) * 20
        const pts: Vec2[] = [[x, y]]
        for (let k = 0; k < 4; k++) {
          if (k % 2) y += (rnd() < 0.5 ? -1 : 1) * Math.round(2 + rnd() * 5) * 20
          else x += (rnd() < 0.5 ? -1 : 1) * Math.round(2 + rnd() * 5) * 20
          pts.push([x, y])
        }
        line(pts)
        g.beginPath()
        g.arc(x, y, 5, 0, Math.PI * 2)
        g.fill()
      }
      break
    case "ashlar":
      for (let r = 0, y = 0; y < TH; r++, y += 46) {
        line([[0, y], [TW, y]])
        for (let x = (r % 2) * 47; x < TW; x += 94) line([[x, y], [x, y + 46]])
      }
      break
    case "rays":
      for (let a = 0; a < 360; a += 5) {
        const t = (a * Math.PI) / 180
        line([[hx + Math.cos(t) * 40, hy + Math.sin(t) * 40], [hx + Math.cos(t) * 1200, hy + Math.sin(t) * 1200]])
      }
      break
    case "vines":
      for (let k = 0; k < 6; k++) {
        const x0 = ((k + 0.5) * TW) / 6
        const pts: Vec2[] = []
        for (let y = -20; y < TH + 20; y += 8) pts.push([x0 + 22 * Math.sin(y / 60 + k), y])
        line(pts)
        for (let y = 30 + k * 13; y < TH; y += 70) {
          const x = x0 + 22 * Math.sin(y / 60 + k)
          const s = ((y / 70) | 0) % 2 ? 1 : -1
          g.beginPath()
          g.ellipse(x + s * 14, y - 6, 12, 5, s * 0.6, 0, Math.PI * 2)
          g.stroke()
        }
      }
      break
    case "scales": {
      const r = 34
      for (let row = 0, y = TH + r; y > -r; row++, y -= r * 0.55) {
        for (let x = (row % 2) * r - r; x < TW + r; x += r * 2) {
          for (const k of [1, 0.68, 0.38]) {
            g.beginPath()
            g.arc(x, y, r * k, Math.PI, 0)
            g.stroke()
          }
        }
      }
      break
    }
    case "starchart": {
      const pts: Vec2[] = []
      for (let i = 0; i < 34; i++) {
        const x = rnd() * TW
        const y = rnd() * TH
        pts.push([x, y])
        g.beginPath()
        g.arc(x, y, 1.5 + rnd() * 3, 0, Math.PI * 2)
        g.fill()
      }
      for (let i = 0; i < 14; i++) line([pts[i], pts[i + 1]])
      g.setLineDash([4, 8])
      for (const r of [0.3, 0.5, 0.72]) circle(cx, cy, r * u)
      g.setLineDash([])
      break
    }
    case "rose":
      g.lineWidth = 1.6
      for (let k = 0; k < 16; k++) {
        const pts: Vec2[] = []
        for (let i = 0; i <= 360; i++) {
          const a = (i / 360) * Math.PI * 2
          const r = (0.2 + 0.06 * Math.sin(a * 12 + k * 0.39) + 0.012 * Math.sin(a * 36)) * u * (1.1 + k * 0.09)
          pts.push([cx + r * Math.cos(a), cy + r * Math.sin(a) * 1.06])
        }
        line(pts)
      }
      break
    case "perlage":
      g.lineWidth = 1.6
      for (let y = 0; y < TH + 40; y += 34) {
        for (let x = ((y / 34) % 2) * 17; x < TW + 40; x += 34) {
          for (let r = 5; r < 26; r += 5) {
            g.beginPath()
            g.arc(x, y, r, 0, Math.PI * 2)
            g.stroke()
          }
        }
      }
      break
    case "meander": {
      const s = 12
      for (let ty = 0; ty < TH; ty += s * 6) {
        for (let tx = 0; tx < TW; tx += s * 6) {
          line([
            [tx, ty + s * 5], [tx, ty], [tx + s * 5, ty], [tx + s * 5, ty + s * 4],
            [tx + s * 2, ty + s * 4], [tx + s * 2, ty + s * 2], [tx + s * 3, ty + s * 2], [tx + s * 3, ty + s * 3],
          ])
        }
      }
      break
    }
    case "damask": {
      g.lineWidth = 1.8
      const s = 58
      for (let y = -s; y < TH + s; y += s) {
        for (let x = -s; x < TW + s; x += s) {
          line([[x, y - s / 2], [x + s / 2, y], [x, y + s / 2], [x - s / 2, y], [x, y - s / 2]])
          g.beginPath()
          g.arc(x, y, 4, 0, Math.PI * 2)
          g.fill()
          g.beginPath()
          g.ellipse(x, y - 12, 3, 7, 0, 0, Math.PI * 2)
          g.stroke()
          g.beginPath()
          g.ellipse(x, y + 12, 3, 7, 0, 0, Math.PI * 2)
          g.stroke()
        }
      }
      break
    }
    case "wyvern": {
      const r = 26
      for (let row = 0, y = -r; y < TH + r; row++, y += r * 0.75) {
        for (let x = (row % 2) * r - r; x < TW + r; x += r * 2) {
          g.beginPath()
          g.moveTo(x - r, y)
          g.quadraticCurveTo(x - r * 0.6, y + r * 1.1, x, y + r * 1.25)
          g.quadraticCurveTo(x + r * 0.6, y + r * 1.1, x + r, y)
          g.stroke()
          g.beginPath()
          g.moveTo(x, y + r * 0.25)
          g.lineTo(x, y + r * 0.9)
          g.stroke()
        }
      }
      break
    }
    case "doors":
      g.lineWidth = 2
      for (let k = 0; k < 11; k++) {
        const s = Math.pow(0.8, k)
        const w = 0.5 * u * s
        const h = 0.72 * u * s
        g.beginPath()
        g.moveTo(cx - w, cy + h * 0.55)
        g.lineTo(cx - w, cy - h * 0.15)
        g.arc(cx, cy - h * 0.15, w, Math.PI, 0)
        g.lineTo(cx + w, cy + h * 0.55)
        g.stroke()
      }
      for (let a = 0; a < 360; a += 10) {
        const t = (a * Math.PI) / 180
        line([[cx + Math.cos(t) * 0.56 * u, cy + Math.sin(t) * 0.6 * u], [cx + Math.cos(t) * 1.3 * u, cy + Math.sin(t) * 1.3 * u]])
      }
      break
  }
}
function paintShell(g: Ctx, sh: Shell, rnd: () => number, seedN: number): void {
  const gr = g.createLinearGradient(0, 0, TW * 0.6, TH)
  gr.addColorStop(0, sh.a)
  gr.addColorStop(1, sh.b)
  g.fillStyle = gr
  g.fillRect(0, 0, TW, TH)
  const add = (c: HTMLCanvasElement, op: number, mode: GlobalCompositeOperation = "overlay"): void => {
    g.globalAlpha = op
    g.globalCompositeOperation = mode
    g.drawImage(c, 0, 0, TW, TH)
    g.globalAlpha = 1
    g.globalCompositeOperation = "source-over"
  }
  add(noiseCanvas(TW, TH, [18, 25], seedN ^ 0x51), 0.22)
  switch (sh.fx) {
    case "linen":
      for (let i = 0; i < TW; i += 3) {
        g.fillStyle = `rgba(90,70,40,${0.05 + rnd() * 0.06})`
        g.fillRect(i, 0, 1, TH)
      }
      for (let j = 0; j < TH; j += 3) {
        g.fillStyle = `rgba(90,70,40,${0.05 + rnd() * 0.06})`
        g.fillRect(0, j, TW, 1)
      }
      break
    case "carbon":
      for (let y = 0; y < TH; y += 10) {
        for (let x = 0; x < TW; x += 10) {
          const on = ((x + y) / 10) % 2
          const cg = g.createLinearGradient(x, y, on ? x + 10 : x, on ? y : y + 10)
          cg.addColorStop(0, "rgba(255,255,255,.02)")
          cg.addColorStop(0.5, "rgba(255,255,255,.16)")
          cg.addColorStop(1, "rgba(0,0,0,.2)")
          g.fillStyle = cg
          g.fillRect(x, y, 10, 10)
        }
      }
      break
    case "frost":
      add(noiseCanvas(TW, TH, [200, 280], seedN ^ 0xf1), 0.35, "soft-light")
      break
    case "walnut":
      g.lineWidth = 1.5
      for (let k = 0; k < 90; k++) {
        g.strokeStyle = `rgba(${k % 3 ? "30,16,8" : "160,110,70"},${0.12 + rnd() * 0.2})`
        g.beginPath()
        const x0 = rnd() * TW
        for (let y = 0; y <= TH; y += 16) {
          const x = x0 + 30 * Math.sin(y / 140 + k) + 8 * Math.sin(y / 31 + k * 2)
          if (y) g.lineTo(x, y)
          else g.moveTo(x, y)
        }
        g.stroke()
      }
      break
    case "brushed":
      for (let y = 0; y < TH; y += 1) {
        g.fillStyle = `rgba(${rnd() < 0.5 ? "255,255,255" : "0,0,0"},${rnd() * 0.07})`
        g.fillRect(0, y, TW, 1)
      }
      break
    case "nacre":
      for (let i = 0; i < 40; i++) {
        const x = rnd() * TW
        const y = rnd() * TH
        const r = 40 + rnd() * 120
        const rg = g.createRadialGradient(x, y, 0, x, y, r)
        rg.addColorStop(0, ["rgba(255,200,230,.5)", "rgba(190,240,255,.5)", "rgba(255,245,200,.5)", "rgba(215,200,255,.5)"][i % 4])
        rg.addColorStop(1, "rgba(255,255,255,0)")
        g.fillStyle = rg
        g.fillRect(0, 0, TW, TH)
      }
      break
    case "facets":
      g.lineWidth = 1.2
      g.strokeStyle = "rgba(255,255,255,.3)"
      for (let i = 0; i < 14; i++) {
        g.beginPath()
        g.moveTo(rnd() * TW, 0)
        g.lineTo(rnd() * TW, TH)
        g.stroke()
      }
      for (let i = 0; i < 9; i++) {
        g.beginPath()
        g.moveTo(0, rnd() * TH)
        g.lineTo(TW, rnd() * TH)
        g.stroke()
      }
      break
    case "stars":
      for (let i = 0; i < 220; i++) {
        g.fillStyle = `rgba(255,255,255,${0.3 + rnd() * 0.7})`
        g.beginPath()
        g.arc(rnd() * TW, rnd() * TH, 0.5 + rnd() * 1.6, 0, Math.PI * 2)
        g.fill()
      }
      break
  }
}
function pack(n: number, ...chans: (Field | number)[]): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(n * 4)
  for (let i = 0; i < n; i++) {
    for (let c = 0; c < 4; c++) {
      const ch = chans[c]
      out[i * 4 + c] = clamp(typeof ch === "number" ? ch : ch[i], 0, 1) * 255
    }
  }
  return out
}

/* ---------------- the rim ----------------
   The rim is the raised band from the card's edge to RIM_IN. Each style is drawn as raised (up)
   and sunken (down) relief, plus stones and a light line for the two rarest, and metal lobes that
   reach past the band's inner edge. Stamps are drawn in the edge's own frame: u runs along the
   edge, w points into the card, and w = 0 is the middle of the band. */
const RIM_IN = 0.036
const RIM_W = U(RIM_IN) / 2

type Rim = {
  up: Field
  down: Field
  gem: Field | null
  gemColors: HTMLCanvasElement | null
  glow: Field | null
  lobe: Field | null
  dome0: number
}

function rimRelief(name: string, corner: Corner): Rim {
  const along = (step: number): OutlinePoint[] => outlinePoints(RIM_IN / 2, corner, step)
  const stamp = (g: Ctx, step: number, draw: (i: number) => void): void =>
    along(step).forEach((p, i) => {
      g.setTransform(p.tx, p.ty, p.nx, p.ny, p.x, p.y)
      draw(i)
    })
  const dome = (g: Ctx, x: number, y: number, r: number): void => {
    const gr = g.createRadialGradient(x - r * 0.25, y - r * 0.25, 0, x, y, r)
    gr.addColorStop(0, "rgba(255,255,255,1)")
    gr.addColorStop(0.7, "rgba(255,255,255,.75)")
    gr.addColorStop(1, "rgba(255,255,255,0)")
    g.fillStyle = gr
    g.beginPath()
    g.arc(x, y, r, 0, Math.PI * 2)
    g.fill()
  }
  const ring = (g: Ctx, inset: number, w: number): void => {
    g.lineWidth = w
    cardPath(g, inset, corner)
    g.stroke()
  }
  const wave = (g: Ctx, amp: number, period: number, phase: number, w: number, alphaOf: ((s: number) => number) | null): void => {
    const pts = along(1.5)
    const o = (s: number): number => amp * Math.sin((s / period) * Math.PI * 2 + phase)
    for (let i = 0; i < pts.length; i++) {
      const p = pts[i]
      const q = pts[(i + 1) % pts.length]
      g.globalAlpha = alphaOf ? alphaOf(p.s) : 1
      g.lineWidth = w
      g.beginPath()
      g.moveTo(p.x + p.nx * o(p.s), p.y + p.ny * o(p.s))
      g.lineTo(q.x + q.nx * o(p.s + 1.5), q.y + q.ny * o(p.s + 1.5))
      g.stroke()
    }
    g.globalAlpha = 1
  }
  const none = (): void => {}
  let up: (g: Ctx) => void = none
  let down: (g: Ctx) => void = none
  let gems: ((g: Ctx) => void) | null = null
  let glow: ((g: Ctx) => void) | null = null
  let lobe: ((g: Ctx) => void) | null = null
  let dome0 = 0.35
  switch (name) {
    case "Plain Bevel":
      dome0 = 1
      break
    case "Double Rule":
      up = g => {
        ring(g, 0.008, 2.6)
        ring(g, 0.028, 2.6)
      }
      dome0 = 0.15
      break
    case "Rope":
      up = g =>
        stamp(g, 5, () => {
          g.beginPath()
          g.ellipse(0, 0, 7.5, 2.3, 0.95, 0, Math.PI * 2)
          g.fill()
        })
      dome0 = 0.2
      break
    case "Beaded":
      up = g => stamp(g, 11.5, () => dome(g, 0, 0, 5.4))
      dome0 = 0.1
      break
    case "Knurled":
      down = g => {
        g.lineWidth = 1.8
        for (let k = -TH; k < TW + TH; k += 5.5) {
          g.beginPath()
          g.moveTo(k, 0)
          g.lineTo(k + TH, TH)
          g.stroke()
          g.beginPath()
          g.moveTo(k, 0)
          g.lineTo(k - TH, TH)
          g.stroke()
        }
      }
      dome0 = 0.6
      break
    case "Stitched":
      up = g => {
        ring(g, 0.004, 1.6)
        ring(g, 0.032, 1.6)
      }
      down = g =>
        stamp(g, 7, () => {
          g.save()
          g.rotate(-0.5)
          g.fillRect(-2.6, -1.1, 5.2, 2.2)
          g.restore()
        })
      dome0 = 0.5
      break
    case "Rivets":
      up = g => stamp(g, 44, () => dome(g, 0, 0, 5.8))
      down = g => {
        ring(g, 0.006, 1)
        ring(g, 0.03, 1)
      }
      dome0 = 0.05
      break
    case "Fluted":
      down = g => stamp(g, 5.5, () => g.fillRect(-1.2, -RIM_W, 2.4, RIM_W * 2))
      dome0 = 0.7
      break
    case "Greek Key":
      up = g => {
        g.lineWidth = 2
        g.lineCap = "square"
        stamp(g, 15, () => {
          g.beginPath()
          const pts: Vec2[] = [[-6, 5], [-6, -5], [5, -5], [5, 3], [-1.5, 3], [-1.5, -1]]
          pts.forEach(([x, y], i) => (i ? g.lineTo(x, y) : g.moveTo(x, y)))
          g.stroke()
        })
        g.setTransform(1, 0, 0, 1, 0, 0)
        g.lineCap = "round"
        ring(g, 0.003, 1.4)
        ring(g, 0.033, 1.4)
      }
      dome0 = 0.1
      break
    case "Scalloped":
      up = g => stamp(g, 22, () => dome(g, 0, RIM_W - 2.5, 11.5))
      lobe = g =>
        stamp(g, 22, () => {
          g.beginPath()
          g.arc(0, RIM_W - 2.5, 10.8, 0, Math.PI * 2)
          g.fill()
        })
      dome0 = 0.3
      break
    case "Twisted Wire":
      up = g => {
        g.strokeStyle = "#fff"
        wave(g, 4, 15, 0, 3.6, s => 0.55 + 0.45 * Math.cos((s / 15) * Math.PI * 2))
        wave(g, 4, 15, Math.PI, 3.6, s => 0.55 - 0.45 * Math.cos((s / 15) * Math.PI * 2))
      }
      dome0 = 0
      break
    case "Chain":
      up = g =>
        stamp(g, 11, i => {
          if (i % 2) {
            g.fillRect(-5.5, -1.5, 11, 3)
          } else {
            g.lineWidth = 2.4
            g.beginPath()
            g.ellipse(0, 0, 6.6, 4.4, 0, 0, Math.PI * 2)
            g.stroke()
          }
        })
      dome0 = 0
      break
    case "Filigree":
      up = g => {
        g.lineWidth = 1.5
        stamp(g, 20, i => {
          const s = i % 2 ? 1 : -1
          g.beginPath()
          g.arc(-4, -2.4 * s, 3.4, 0, Math.PI * 1.6 * s, s < 0)
          g.stroke()
          g.beginPath()
          g.arc(4, 2.4 * s, 3.4, Math.PI, Math.PI + Math.PI * 1.6 * s, s < 0)
          g.stroke()
          g.beginPath()
          g.moveTo(-4, 1 * s)
          g.quadraticCurveTo(0, 0, 4, -1 * s)
          g.stroke()
          g.beginPath()
          g.arc(9.5, 0, 1.3, 0, Math.PI * 2)
          g.fill()
        })
      }
      dome0 = 0.25
      break
    case "Engine-Turned":
      up = g => {
        for (let k = 0; k < 7; k++) wave(g, 6.5, 26, k * 0.9, 1, null)
      }
      dome0 = 0.45
      break
    case "Jewelled":
      up = g =>
        stamp(g, 50, () => {
          g.lineWidth = 2.2
          g.beginPath()
          g.arc(0, 0, 7, 0, Math.PI * 2)
          g.stroke()
          dome(g, 0, 0, 5.6)
        })
      gems = g =>
        stamp(g, 50, i => {
          g.fillStyle = GEMS[i % GEMS.length]
          g.beginPath()
          g.arc(0, 0, 5.6, 0, Math.PI * 2)
          g.fill()
        })
      dome0 = 0.6
      break
    case "Light Seam":
      down = g => ring(g, RIM_IN / 2, 4.4)
      glow = g => {
        g.filter = "blur(6px)"
        g.globalAlpha = 0.55
        ring(g, RIM_IN / 2, 12)
        g.filter = "none"
        g.globalAlpha = 1
        ring(g, RIM_IN / 2, 3)
      }
      dome0 = 0.9
      break
  }
  let gemColors: HTMLCanvasElement | null = null
  if (gems) {
    gemColors = canvas()
    gems(g2d(gemColors))
  }
  return {
    up: mask(up),
    down: mask(down),
    gem: gems ? mask(gems) : null,
    gemColors,
    glow: glow ? mask(glow) : null,
    lobe: lobe ? mask(lobe) : null,
    dome0,
  }
}

/* ---------------- the locked card ---------------- */
/** The Regents crown sits CROWN_IN from the left and bottom edges: blocks of CROWN_B px with CROWN_G px gaps. */
const CROWN_IN = 0.1
const CROWN_B = 14
const CROWN_G = 3
function crownBox(): {x: number; y: number; w: number; h: number} {
  const w = 5 * CROWN_B + 4 * CROWN_G
  const h = 3 * CROWN_B + 2 * CROWN_G
  return {x: U(CROWN_IN), y: TH - U(CROWN_IN) - h, w, h}
}

/**
 * A Regents Club card's mark: "CLUB" over "PASS", a block as tall as the crown across from it, its right
 * edge as far in as the crown's left. Stacked, it stays clear of a title along the bottom.
 */
const PASS = ["CLUB", "PASS"]
const PASS_PX = 22
const PASS_TRACK = 4
/** A Regents Club card's enamel, under its crest and around its face. */
const CLUB_ENAMEL = "#101013"
function passMarkBox(): {x: number; y: number; w: number; h: number} {
  const g = g2d(canvas(1, 1))
  g.font = `700 ${PASS_PX}px ${DISPLAY_FONT}`
  const width = (word: string): number => [...word].reduce((sum, ch) => sum + g.measureText(ch).width, 0) + PASS_TRACK * (word.length - 1)
  const w = Math.max(...PASS.map(width))
  const cb = crownBox()
  return {x: TW - cb.x - w, y: cb.y, w, h: cb.h}
}

function buildExterior(key: Key, masks: KeyMasks, seedN: number, topLine: string, look: Look): CardLayers {
  const ext = EXTERIORS[key.exterior]
  const sh = SHELLS[key.shell]
  const rnd = prng(seedN ^ 0xe7)
  const pl = placement(ext)
  const N = TW * TH
  const inset = (d: number): Field =>
    mask(g => {
      cardPath(g, d, ext.corner)
      g.fill()
    })
  const sil = inset(0)
  const inRim = inset(RIM_IN)
  const face = inset(0.052)
  const hairOut = inset(0.06)
  const hairIn = inset(0.064)
  const hair = mapF(hairOut, (x, i) => x - hairIn[i])
  const band = mapF(sil, (x, i) => x - inRim[i])
  const rim = rimRelief(key.rim, ext.corner)
  const rimDome = blur(band, TW, TH, 4)
  const keyAt = mask(g => {
    keyTransform(g, pl)
    g.drawImage(masks.whole, 0, 0)
  })
  const kb = blur(keyAt, TW, TH, 5)
  const kb2 = blur(keyAt, TW, TH, 11)
  const slot = mapF(kb, x => sstep(0.03, 0.2, x))
  const lip = mapF(kb2, (x, i) => sstep(0.02, 0.09, x) * (1 - slot[i]))
  const lipZone = mapF(kb2, x => sstep(0.005, 0.04, x))
  const crestR = 0.19
  const ccx = X(pl.crest[0])
  const ccy = Y(pl.crest[1])
  const atCrest = (draw: (g: Ctx) => void): Field =>
    mask(g => {
      g.setTransform(1, 0, 0, 1, ccx, ccy)
      draw(g)
    })
  const crestOuter = atCrest(g => {
    crestPath(g, ext.crest, crestR)
    g.fill()
  })
  const crestField = atCrest(g => {
    crestPath(g, ext.crest, crestR - 0.022)
    g.fill()
  })
  const crestTicks = atCrest(g => {
    g.lineWidth = 2
    for (let a = 0; a < 360; a += 15) {
      const t = (a * Math.PI) / 180
      const r0 = U(crestR - 0.052)
      const r1 = U(crestR - 0.036)
      g.beginPath()
      g.moveTo(r0 * Math.cos(t), r0 * Math.sin(t))
      g.lineTo(r1 * Math.cos(t), r1 * Math.sin(t))
      g.stroke()
    }
  })
  const emblemPx = U(0.21 * 1.08)
  const emblem = mask(g => g.drawImage(masks.emblem, ccx - emblemPx / 2, ccy - emblemPx / 2, emblemPx, emblemPx))
  const cb = crownBox()
  const crown = mask(g =>
    CROWN_BLOCKS.forEach(([c, r]) => g.fillRect(cb.x + c * (CROWN_B + CROWN_G), cb.y + r * (CROWN_B + CROWN_G), CROWN_B, CROWN_B)),
  )
  // A thin enamel line in a tone that contrasts with the crown's material outlines every block, so the crown reads on every card.
  const crownPlate = mask(g =>
    CROWN_BLOCKS.forEach(([c, r]) =>
      g.fillRect(cb.x + c * (CROWN_B + CROWN_G) - 2, cb.y + r * (CROWN_B + CROWN_G) - 2, CROWN_B + 4, CROWN_B + 4),
    ),
  )
  const crownLine = mapF(crownPlate, (x, i) => x * (1 - crown[i]))
  const lineTone = hexRgb(lum(CROWNS[key.crown].c) > 0.3 ? "#16161a" : "#ece8e0")
  const crownZone = mask(g => g.fillRect(cb.x - 8, cb.y - 8, cb.w + 16, cb.h + 16))
  const passBox = passMarkBox()
  const passZone = mask(g => {
    if (look === "regentsClub") g.fillRect(passBox.x - 8, passBox.y - 8, passBox.w + 16, passBox.h + 16)
  })
  const orn = mask(g => eachCorner(g, look, () => cornerOrnament(g, ext.orn)))
  const titleY = Y(pl.title)
  const title = mask(g => {
    g.textAlign = "left"
    g.textBaseline = "middle"
    g.font = `700 34px ${DISPLAY_FONT}`
    spaced(g, "KEYFLEET", TW / 2, titleY, 7)
    g.font = `600 17px ${LABEL_FONT}`
    spaced(g, topLine, TW / 2, titleY + (pl.title < 0 ? 36 : -36), 3)
    if (look === "regentsClub") {
      g.font = `700 ${PASS_PX}px ${DISPLAY_FONT}`
      PASS.forEach((word, row) => spaced(g, word, passBox.x + passBox.w / 2, passBox.y + passBox.h * (row ? 0.78 : 0.22), PASS_TRACK))
    }
  })
  // A soft dark edge around the lettering keeps the top line readable on pale cards and bright foil.
  const halo = mapF(blur(title, TW, TH, 3), (x, i) => sstep(0.02, 0.3, x) * (1 - title[i]))
  const titleZone = mask(g => g.fillRect(0, titleY - (pl.title < 0 ? 30 : 58), TW, 88))
  const lines = mask(g => motif(g, ext.motif, pl, rnd))
  const open = mapF(face, (f, i) => f * (1 - lipZone[i]) * (1 - crestOuter[i]) * (1 - titleZone[i]) * (1 - crownZone[i]) * (1 - passZone[i]))
  const G = mapF(lines, (x, i) => x * open[i])
  const ornM = mapF(orn, (x, i) => x * (1 - lipZone[i]))

  const T = new Float32Array(N)
  const M = new Float32Array(N)
  setLevel(T, sil, 0.72)
  setLevel(M, sil, 1)
  for (let i = 0; i < N; i++) {
    const relief = 0.58 + 0.14 * rim.dome0 * sstep(0.15, 0.9, rimDome[i]) + 0.16 * rim.up[i] - 0.2 * rim.down[i]
    T[i] += (relief - T[i]) * band[i]
  }
  setLevel(T, inRim, 0.3)
  setLevel(M, inRim, 0)
  if (rim.lobe) {
    setLevel(T, rim.lobe, 0.62)
    setLevel(M, rim.lobe, 1)
  }
  setLevel(T, face, 0.47)
  setLevel(T, hair, 0.62)
  setLevel(M, hair, 1)
  for (let i = 0; i < N; i++) {
    if (ext.inlay) {
      T[i] += G[i] * 0.05
      M[i] += (1 - M[i]) * G[i]
    } else {
      T[i] -= G[i] * 0.09
    }
  }
  setLevel(T, ornM, 0.74)
  setLevel(M, ornM, 1)
  setLevel(T, crestOuter, 0.72)
  setLevel(M, crestOuter, 1)
  setLevel(T, crestField, 0.4)
  setLevel(M, crestField, 0)
  setLevel(T, crestTicks, 0.55)
  setLevel(M, crestTicks, 1)
  setLevel(T, emblem, 0.7)
  setLevel(M, emblem, 1)
  setLevel(T, crownLine, 0.52)
  setLevel(M, crownLine, 0)
  setLevel(T, crown, 0.76)
  setLevel(M, crown, 1)
  setLevel(T, title, 0.6)
  setLevel(M, title, 1)
  setLevel(T, lip, 0.64)
  setLevel(M, lip, 1)
  setLevel(T, slot, 0.1)
  setLevel(M, slot, 0)
  if (rim.gem) setLevel(M, rim.gem, 0)
  const Tb = blur(T, TW, TH, 1, 2)
  const edge = blur(sil, TW, TH, 5)
  const H = mapF(Tb, (h, i) => h * (0.55 + 0.45 * sstep(0.5, 1, edge[i])))
  const Fm = mapF(face, (f, i) => f * (1 - M[i]) * (1 - slot[i]) * (1 - 0.8 * halo[i]) * (1 - crownLine[i]))

  const alb = canvas()
  const a = g2d(alb)
  a.fillStyle = "#f4f4f4"
  a.fillRect(0, 0, TW, TH)
  const enamel = look === "regentsClub" ? CLUB_ENAMEL : sh.dark ? mix(sh.b, "#000", 0.45) : mix(sh.b, "#2a2420", 0.5)
  a.fillStyle = enamel
  cardPath(a, RIM_IN, ext.corner)
  a.fill()
  a.save()
  cardPath(a, 0.052, ext.corner)
  a.clip()
  paintShell(a, sh, rnd, seedN)
  a.restore()
  const ad = a.getImageData(0, 0, TW, TH).data
  const gd = rim.gemColors && g2d(rim.gemColors).getImageData(0, 0, TW, TH).data
  const [er, eg, eb] = hexRgb(enamel)
  const [vr, vg, vb] = hexRgb(mix(sh.b, "#050406", 0.8))
  const albOut = new Uint8Array(N * 4)
  for (let i = 0; i < N; i++) {
    let r = ad[i * 4]
    let gg = ad[i * 4 + 1]
    let b = ad[i * 4 + 2]
    const cf = crestField[i]
    const sl = slot[i]
    const ink = ext.inlay ? 0 : G[i] * 0.24
    const m = M[i]
    r += (er - r) * cf
    gg += (eg - gg) * cf
    b += (eb - b) * cf
    r += (vr - r) * sl
    gg += (vg - gg) * sl
    b += (vb - b) * sl
    const dim = (1 - ink) * (1 - 0.7 * halo[i])
    r *= dim
    gg *= dim
    b *= dim
    const mt = 236 - 40 * G[i] * (ext.inlay ? 0 : 1)
    r += (mt - r) * m
    gg += (mt - gg) * m
    b += (mt - b) * m
    const cl = crownLine[i]
    r += (lineTone[0] - r) * cl
    gg += (lineTone[1] - gg) * cl
    b += (lineTone[2] - b) * cl
    if (gd && rim.gem) {
      const s = rim.gem[i]
      r += (gd[i * 4] - r) * s
      gg += (gd[i * 4 + 1] - gg) * s
      b += (gd[i * 4 + 2] - b) * s
    }
    albOut[i * 4] = r
    albOut[i * 4 + 1] = gg
    albOut[i * 4 + 2] = b
    albOut[i * 4 + 3] = sil[i] * 255
  }
  return {w: TW, h: TH, alb: albOut, aux: pack(N, H, M, Fm, G), mat: pack(N, crown, rim.gem ?? 0, rim.glow ?? 0, look === "regentsClub" ? title : 0), pl}
}

/* ---------------- everything for one key ---------------- */
/** Where the light sits, in card units from the card's middle (x right, y down). */
const LIGHT: Vec2 = [0.35, -0.7]
const rgb = (hex: string): number[] => hexRgb(hex).map(x => x / 255)

/** Everything the shader needs from the key's traits. */
export type CardUniforms = {
  light: Vec2
  keyOrigin: Vec2
  keyAxis: Vec2
  metal: number[]
  metalRough: number
  metalKind: number
  crown: number[]
  crownRough: number
  crownKind: number
  patina: number
  shellGloss: number
  shellMetal: number
  shellClear: number
  shellPearl: number
  foilKind: number
}
export type CardJob = {paint: {exterior: CardLayers; key: Layers}; uniforms: CardUniforms}

function traitUniforms(key: Key, pl: Placement): CardUniforms {
  const m = METALS[key.metal]
  const cr = CROWNS[key.crown]
  const sh = SHELLS[key.shell]
  return {
    light: LIGHT,
    keyOrigin: pl.origin,
    keyAxis: pl.axis,
    metal: rgb(m.c),
    metalRough: m.rough,
    metalKind: m.kind,
    crown: rgb(cr.c),
    crownRough: cr.rough,
    crownKind: cr.kind,
    patina: indexOf("patina", key.patina),
    shellGloss: sh.gloss,
    shellMetal: sh.metal ?? 0,
    shellClear: sh.clear ?? 0,
    shellPearl: sh.pearl ?? 0,
    foilKind: indexOf("foil", key.foil),
  }
}

/** A key's card for the renderer: its painted layers and the shader settings its traits give. */
export async function keyJob(key: Key, seedN: number, topLine: string): Promise<CardJob> {
  await fontsReady()
  const masks = await keyMasks(key)
  const exterior = buildExterior(key, masks, seedN, topLine, lookOf(topLine))
  return {paint: {exterior, key: buildKey(METALS[key.metal], masks, seedN)}, uniforms: traitUniforms(key, exterior.pl)}
}
