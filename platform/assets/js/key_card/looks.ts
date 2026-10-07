/**
 * What each trait value looks like on the card: the layout each exterior builds, the materials,
 * the emblems and the cut of each key's blade. Values are named exactly as in the trait table.
 */

export type Side = "left" | "right" | "top" | "bottom"
export type Corner = "round" | "chamfer" | "notch"
export type Crest = "circle" | "diamond" | "hex" | "shield" | "arch"
export type Ornament = "studs" | "brackets" | "fans" | "leaves" | "stars" | "scrolls"
export type Motif =
  | "waves" | "ruled" | "rings" | "chevrons" | "circuit" | "ashlar" | "rays" | "vines"
  | "scales" | "starchart" | "rose" | "perlage" | "meander" | "damask" | "wyvern" | "doors"

/**
 * side: the card edge the slot opens on. blade: the cut of the key that fits the slot.
 * motif: the engraving. orn: corner ornaments. crest: the medallion shape. corner: the card's
 * outline. inlay: engraving filled with metal.
 */
export type Exterior = {
  readonly side: Side
  readonly blade: string
  readonly motif: Motif
  readonly orn: Ornament
  readonly crest: Crest
  readonly corner: Corner
  readonly inlay?: boolean
}

export const EXTERIORS: Readonly<Record<string, Exterior>> = {
  Harbor: {side: "bottom", blade: "Single Bit", motif: "waves", orn: "studs", crest: "circle", corner: "round"},
  Ledger: {side: "right", blade: "Stepped", motif: "ruled", orn: "brackets", crest: "diamond", corner: "chamfer"},
  Signal: {side: "left", blade: "Sawtooth", motif: "rings", orn: "brackets", crest: "circle", corner: "round"},
  Relay: {side: "top", blade: "Double Bit", motif: "chevrons", orn: "brackets", crest: "diamond", corner: "chamfer"},
  Circuit: {side: "right", blade: "Dimple", motif: "circuit", orn: "brackets", crest: "hex", corner: "chamfer"},
  Quarry: {side: "bottom", blade: "Ward", motif: "ashlar", orn: "studs", crest: "shield", corner: "notch"},
  Lantern: {side: "left", blade: "Barrel", motif: "rays", orn: "fans", crest: "circle", corner: "round"},
  Orchard: {side: "top", blade: "Wave", motif: "vines", orn: "leaves", crest: "circle", corner: "round"},
  Tidewater: {side: "right", blade: "Spiral", motif: "scales", orn: "fans", crest: "circle", corner: "round"},
  Observatory: {side: "top", blade: "Floating Pins", motif: "starchart", orn: "stars", crest: "circle", corner: "round"},
  Cathedral: {side: "bottom", blade: "Lattice", motif: "rose", orn: "scrolls", crest: "arch", corner: "notch", inlay: true},
  Foundry: {side: "left", blade: "Comb", motif: "perlage", orn: "studs", crest: "hex", corner: "chamfer"},
  Labyrinth: {side: "right", blade: "Flag", motif: "meander", orn: "brackets", crest: "diamond", corner: "chamfer"},
  "Crown Vault": {side: "top", blade: "Twin Blade", motif: "damask", orn: "scrolls", crest: "shield", corner: "notch", inlay: true},
  Wyvern: {side: "left", blade: "Lightning", motif: "wyvern", orn: "fans", crest: "shield", corner: "round"},
  "The First Door": {side: "bottom", blade: "Crystal", motif: "doors", orn: "scrolls", crest: "arch", corner: "notch", inlay: true},
}

/**
 * Key Material plates the key and every metal part of the card except the Regents crown.
 * kind: 0 metal, 1 glazed or stone, 2 opal, 3 glass, 4 starlight, 5 heat-blued steel.
 */
export type Metal = {
  readonly c: string
  readonly rough: number
  readonly kind: number
  readonly fx?: "brushed" | "jade" | "damascus" | "opal" | "meteor"
}

export const METALS: Readonly<Record<string, Metal>> = {
  "Brushed Steel": {c: "#c9ccd0", rough: 0.34, kind: 0, fx: "brushed"},
  Brass: {c: "#e3b862", rough: 0.24, kind: 0},
  Nickel: {c: "#dcd9cf", rough: 0.18, kind: 0},
  Graphite: {c: "#555a62", rough: 0.38, kind: 0},
  Copper: {c: "#e59a6a", rough: 0.24, kind: 0},
  "Bone Ceramic": {c: "#efe6d3", rough: 0.5, kind: 1},
  Pewter: {c: "#a1a4a5", rough: 0.46, kind: 0},
  "Rose Gold": {c: "#f1b9a4", rough: 0.2, kind: 0},
  Jade: {c: "#3f9a74", rough: 0.28, kind: 1, fx: "jade"},
  "Blued Steel": {c: "#4a66b8", rough: 0.2, kind: 5},
  Gold: {c: "#ffcf58", rough: 0.14, kind: 0},
  Damascus: {c: "#b2b8bf", rough: 0.3, kind: 0, fx: "damascus"},
  Opal: {c: "#f1f2fb", rough: 0.14, kind: 2, fx: "opal"},
  Glass: {c: "#d7efff", rough: 0.06, kind: 3},
  Meteorite: {c: "#9095a0", rough: 0.3, kind: 0, fx: "meteor"},
  Starlight: {c: "#fff0c8", rough: 0.12, kind: 4},
}

/** Card Shell: the face of the locked card. gloss 0..1, metal 0..1, clear (see-through), pearl (iridescent). */
export type Shell = {
  readonly a: string
  readonly b: string
  readonly gloss: number
  readonly dark?: number
  readonly metal?: number
  readonly clear?: number
  readonly pearl?: number
  readonly fx?: "linen" | "carbon" | "frost" | "walnut" | "brushed" | "nacre" | "facets" | "stars"
}

export const SHELLS: Readonly<Record<string, Shell>> = {
  "Matte Graphite": {a: "#3a3f47", b: "#23262c", gloss: 0.12, dark: 1},
  Pearl: {a: "#f3efea", b: "#d9d2cb", gloss: 0.55, pearl: 0.35},
  "Powder Blue Ceramic": {a: "#d5e5f5", b: "#97b6d8", gloss: 0.6},
  "Sage Enamel": {a: "#c4d2b5", b: "#8aa083", gloss: 0.5},
  "Sand Linen": {a: "#e8d8ba", b: "#c9b38c", gloss: 0.08, fx: "linen"},
  "Carbon Weave": {a: "#34373c", b: "#15171a", gloss: 0.45, dark: 1, fx: "carbon"},
  "Ivory Porcelain": {a: "#fffcf2", b: "#e8dec9", gloss: 0.7},
  "Frosted Glass": {a: "#e2ecf7", b: "#b9c9dc", gloss: 0.25, clear: 0.35, fx: "frost"},
  Walnut: {a: "#6d4529", b: "#3b2314", gloss: 0.35, dark: 1, fx: "walnut"},
  "Brushed Aluminum": {a: "#d9dde2", b: "#a0a7b0", gloss: 0.5, metal: 0.75, fx: "brushed"},
  "Red Lacquer": {a: "#b8292b", b: "#6c1115", gloss: 0.85, dark: 1},
  "Mother of Pearl": {a: "#f6ecf3", b: "#dcebf2", gloss: 0.6, pearl: 1, fx: "nacre"},
  Obsidian: {a: "#1a1720", b: "#060508", gloss: 0.9, dark: 1},
  "Clear Crystal": {a: "#c9d4e2", b: "#8b9bb0", gloss: 0.9, clear: 0.7, dark: 1, fx: "facets"},
  "Liquid Mercury": {a: "#c9ced4", b: "#6c737c", gloss: 1, metal: 1},
  "Night Sky": {a: "#172a5c", b: "#050918", gloss: 0.55, dark: 1, fx: "stars"},
}

/** Regents Crown: the thirteen-block crown in the bottom-left corner, in its own material. Same kinds as Key Material. */
export const CROWNS: Readonly<Record<string, Metal>> = {
  Pewter: {c: "#a1a4a5", rough: 0.46, kind: 0},
  Steel: {c: "#c9ccd0", rough: 0.3, kind: 0},
  Brass: {c: "#e3b862", rough: 0.24, kind: 0},
  Copper: {c: "#e59a6a", rough: 0.24, kind: 0},
  Bronze: {c: "#c98a4e", rough: 0.32, kind: 0},
  Silver: {c: "#eceef0", rough: 0.14, kind: 0},
  "White Enamel": {c: "#f3f0e8", rough: 0.3, kind: 1},
  "Black Enamel": {c: "#2a2a30", rough: 0.22, kind: 1},
  "Rose Gold": {c: "#f1b9a4", rough: 0.2, kind: 0},
  Jade: {c: "#3f9a74", rough: 0.28, kind: 1},
  Gold: {c: "#ffcf58", rough: 0.14, kind: 0},
  Platinum: {c: "#e6e6e2", rough: 0.1, kind: 0},
  "Blued Steel": {c: "#4a66b8", rough: 0.2, kind: 5},
  Opal: {c: "#f1f2fb", rough: 0.14, kind: 2},
  "Ruby Glass": {c: "#e8233c", rough: 0.06, kind: 3},
  Starlight: {c: "#fff0c8", rough: 0.12, kind: 4},
}

/** The crown as blocks on a 5 x 3 grid, from the Regents logo: three on top (columns 1, 3, 5), then two full rows. */
export const CROWN_BLOCKS: readonly (readonly [number, number])[] = [
  [0, 0], [2, 0], [4, 0], [0, 1], [1, 1], [2, 1], [3, 1], [4, 1], [0, 2], [1, 2], [2, 2], [3, 2], [4, 2],
]
/** Jewelled rims set these stones in turn. */
export const GEMS = ["#d81e3c", "#1f5fd6", "#14a05a", "#f4f4ff"] as const

/* ---------------- shape helpers: SVG elements, white unless told otherwise ---------------- */
const W = "#fff"
const K = "#000"
const f1 = (n: number): number => Math.round(n * 10) / 10
const C = (x: number, y: number, r: number, f = W): string => `<circle cx="${x}" cy="${y}" r="${r}" fill="${f}"/>`
const E = (x: number, y: number, rx: number, ry: number, f = W): string =>
  `<ellipse cx="${x}" cy="${y}" rx="${rx}" ry="${ry}" fill="${f}"/>`
const R = (x: number, y: number, w: number, h: number, rx = 0, f = W): string =>
  `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${rx}" fill="${f}"/>`
const P = (d: string, f = W): string => `<path d="${d}" fill="${f}"/>`
const S = (d: string, f = W, w = 6): string =>
  `<path d="${d}" fill="none" stroke="${f}" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round"/>`
const PG = (pts: string, f = W, j = 0): string =>
  `<polygon points="${pts}" fill="${f}" ${j ? `stroke="${f}" stroke-width="${j}" stroke-linejoin="round"` : ""}/>`

function starPts(cx: number, cy: number, ro: number, ri: number, n = 5, rot = -90): string {
  const p: string[] = []
  for (let i = 0; i < n * 2; i++) {
    const a = ((rot + (i * 180) / n) * Math.PI) / 180
    const r = i % 2 ? ri : ro
    p.push(`${f1(cx + r * Math.cos(a))},${f1(cy + r * Math.sin(a))}`)
  }
  return p.join(" ")
}

/* ---------------- emblems and key outlines ----------------
   Each emblem is drawn upright around (64, 65), inside a circle of radius about 50. The medallion
   shows it upright. The key's handle is the same shape, also upright as seen on the card, whichever
   side the key comes from. */
const spiralPath = (): string => {
  const p: string[] = []
  for (let i = 0; i <= 120; i++) {
    const t = i / 120
    const a = Math.PI / 2 - (1 - t) * Math.PI * 4.5
    const r = 5 + t * 39
    p.push(`${f1(64 + r * Math.cos(a))} ${f1(65 + r * Math.sin(a))}`)
  }
  return "M" + p.join("L")
}
const infinityPath = (): string => {
  const p: string[] = []
  for (let i = 0; i <= 120; i++) {
    const t = (i / 120) * Math.PI * 2
    const d = 1 + Math.sin(t) ** 2
    p.push(`${f1(64 + (44 * Math.cos(t)) / d)} ${f1(65 + ((44 * Math.sin(t) * Math.cos(t)) / d) * 1.25)}`)
  }
  return "M" + p.join("L") + "Z"
}
const sunRays = (): string[] =>
  Array.from({length: 12}, (_, i) => {
    const a = (i * Math.PI) / 6 + Math.PI / 2
    const c = Math.cos(a)
    const s = Math.sin(a)
    const q = (r: number, w: number): string => `${f1(64 + r * c - w * s)},${f1(65 + r * s + w * c)}`
    return PG(`${q(26, -8)} ${q(50, 0)} ${q(26, 8)}`, W, 3)
  })
const gearPts = (): string => {
  const p: string[] = []
  for (let i = 0; i < 48; i++) {
    const a = ((i * 7.5 + 3.75) * Math.PI) / 180
    const r = i % 4 < 2 ? 50 : 40
    p.push(`${f1(64 + r * Math.cos(a))},${f1(65 + r * Math.sin(a))}`)
  }
  return p.join(" ")
}

export const EMBLEMS: Readonly<Record<string, () => string[]>> = {
  Crescent: () => [C(64, 65, 48), C(84, 50, 38, K)],
  "Keyhole Ring": () => [C(64, 65, 48), C(64, 65, 35, K), C(64, 54, 14), PG("57,58 71,58 78,104 50,104")],
  Sun: () => [...sunRays(), C(64, 65, 29), C(64, 65, 12, K)],
  Star: () => [PG(starPts(64, 68, 52, 23), W, 6), C(64, 70, 8, K)],
  Leaf: () => [
    P("M64 12C102 34 106 80 64 106C22 80 26 34 64 12Z"),
    R(60, 100, 8, 16, 3),
    S("M64 30V92", K, 4),
    S("M64 48L82 34M64 64L86 50M64 80L82 70M64 48L46 34M64 64L42 50M64 80L46 70", K, 3),
  ],
  Wave: () => [
    C(64, 65, 48),
    S("M28 46Q37 36 46 46T64 46T82 46T100 46", K, 6),
    S("M22 65Q32 55 42 65T62 65T82 65T104 65", K, 6),
    S("M28 84Q37 74 46 84T64 84T82 84T100 84", K, 6),
  ],
  Anchor: () => [
    C(64, 24, 12),
    C(64, 24, 5, K),
    R(59, 32, 10, 70, 2),
    R(38, 42, 52, 9, 4),
    S("M24 74Q28 106 64 108Q100 106 104 74", W, 9),
    PG("14,80 32,68 32,86", W, 3),
    PG("114,80 96,68 96,86", W, 3),
  ],
  Eye: () => [P("M12 65Q64 14 116 65Q64 116 12 65Z"), C(64, 65, 19, K), E(64, 65, 6, 24)],
  Bolt: () => [PG("78,10 28,70 60,70 48,120 102,52 70,52 88,10", W, 5)],
  Heart: () => [
    P("M64 112C24 84 14 56 28 38C41 22 57 26 64 40C71 26 87 22 100 38C114 56 104 84 64 112Z"),
    C(64, 62, 11, K),
  ],
  Gear: () => [
    PG(gearPts(), W, 3),
    C(64, 65, 15, K),
    ...[45, 135, 225, 315].map(d =>
      C(f1(64 + 28 * Math.cos((d * Math.PI) / 180)), f1(65 + 28 * Math.sin((d * Math.PI) / 180)), 6, K),
    ),
  ],
  Compass: () => [
    C(64, 65, 48),
    C(64, 65, 39, K),
    PG(starPts(64, 65, 46, 10, 4), W, 2),
    PG(starPts(64, 65, 30, 8, 4, -45), W, 2),
    C(64, 65, 4, K),
  ],
  Flame: () => [
    P("M64 10C78 34 100 48 100 78C100 102 84 116 64 116C44 116 28 102 28 80C28 64 38 54 46 42C48 56 54 62 60 66C56 46 58 28 64 10Z"),
    P("M64 60C71 72 81 80 79 93C77 101 71 105 64 105C57 105 51 101 49 93C47 83 58 74 64 60Z", K),
  ],
  Crown: () => [
    PG("20,100 24,30 44,58 64,18 84,58 104,30 108,100", W, 8),
    C(24, 27, 7),
    C(64, 15, 7),
    C(104, 27, 7),
    C(64, 78, 9, K),
  ],
  Spiral: () => [S(spiralPath(), W, 10), C(64, 65, 8)],
  Infinity: () => [S(infinityPath(), W, 11)],
}

/** The emblem alone, white on clear, for the medallion. */
export const emblemSvg = (shapes: string): string =>
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="10 11 108 108" width="256" height="256"><defs><mask id="m" maskUnits="userSpaceOnUse" x="0" y="0" width="128" height="130"><rect width="128" height="130" fill="#000"/>${shapes}</mask></defs><rect width="128" height="130" fill="#fff" mask="url(#m)"/></svg>`

/** The whole key, white on clear, in key units: 340 long and 130 across. */
export const keySvg = (shapes: string, width: number, height: number): string =>
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 340 130" width="${width}" height="${height}"><defs><mask id="m" maskUnits="userSpaceOnUse" x="0" y="0" width="340" height="130"><rect width="340" height="130" fill="#000"/>${shapes}</mask></defs><rect width="340" height="130" fill="#fff" mask="url(#m)"/></svg>`

/**
 * The turn, in key units, that stands the emblem upright on the card for each slot side. The
 * shaft starts at x = 100 and the key's middle line is y = 65.
 */
export const UPRIGHT: Readonly<Record<Side, number>> = {left: 0, right: 180, top: -90, bottom: 90}
/** The neck from the emblem's edge nearest the blade to the shaft, for emblems that stop short of it. */
export const neck = (reach: number): string => (reach < 108 ? R(reach - 4, 58, 116 - reach, 14, 3) : "")
/** The shaft, its collar and its tip, the same on every key. */
export const SHAFT = [R(100, 57, 212, 16, 3), R(100, 49, 10, 32, 4), R(114, 51, 6, 28, 3), PG("308,57 324,65 308,73", W, 4)]

export const BLADES: Readonly<Record<string, () => string[]>> = {
  "Single Bit": () => [R(262, 71, 36, 30, 4)],
  "Double Bit": () => [R(262, 71, 36, 28, 4), R(262, 31, 36, 28, 4)],
  Stepped: () => [P("M236 71H306V84H292V97H274V88H256V102H236Z")],
  Wave: () => [P("M236 71H306V82C300 100 290 100 284 88C278 76 270 76 264 90C258 104 246 102 240 90L236 82Z")],
  Sawtooth: () => [PG("236,71 306,71 306,84 298,96 290,84 282,98 274,84 266,98 258,84 250,96 242,84 236,92")],
  Flag: () => [R(274, 71, 32, 34, 3), PG("274,106 290,93 306,106", K)],
  Comb: () => [0, 1, 2, 3, 4, 5].map(i => R(240 + i * 11, 71, 6, 22 + (i % 2) * 9, 2)),
  Ward: () => [R(254, 71, 50, 34, 4), R(262, 80, 6, 26, 1, K), R(276, 71, 6, 22, 1, K), R(290, 84, 6, 22, 1, K)],
  Barrel: () => [R(268, 71, 30, 24, 4), R(284, 62, 34, 6, 3, K)],
  "Twin Blade": () => [R(244, 71, 22, 26, 3), R(284, 71, 22, 20, 3), R(256, 33, 22, 26, 3), R(292, 39, 14, 20, 3)],
  Spiral: () => [S("M268 71C268 98 302 100 302 84C302 72 284 72 284 84C284 91 294 91 294 85", W, 6)],
  Lattice: () => {
    const o = [R(250, 71, 54, 34, 4)]
    for (let i = 0; i < 3; i++) for (let j = 0; j < 2; j++) o.push(R(256 + i * 16, 76 + j * 14, 8, 8, 1, K))
    return o
  },
  Dimple: () => {
    const o = [R(226, 52, 84, 26, 7), R(268, 76, 26, 16, 3)]
    for (let i = 0; i < 6; i++) for (let j = 0; j < 2; j++) o.push(C(236 + i * 12, 60 + j * 10, 2.8, K))
    return o
  },
  Crystal: () => [
    PG("240,71 254,71 247,98", W, 2),
    PG("256,71 272,71 264,108", W, 2),
    PG("274,71 288,71 281,94", W, 2),
    PG("290,71 304,71 297,104", W, 2),
  ],
  Lightning: () => [PG("250,71 300,71 284,84 298,84 262,114 274,92 256,92", W, 3)],
  "Floating Pins": () => [C(250, 88, 6), C(268, 99, 5), C(284, 86, 6), C(300, 100, 5), C(262, 113, 4)],
}
