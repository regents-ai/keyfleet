/**
 * The harbour's shapes, built from boxes, cones and prisms. Every face is flat:
 * the shader takes each face's slope from the screen, so a vertex is only where
 * it is, what it is made of, and how far the wind may move it.
 */
import {ISLETS, PLACES, type Island} from "./sim"

/** position xyz, material, sway */
export const VERTEX_FLOATS = 5

/** Material codes; the parts shader switches on the same numbers. */
export const MATERIAL = {
  sand: 0,
  grass: 1,
  rock: 2,
  wood: 3,
  plaster: 4,
  roof: 5,
  stone: 6,
  window: 7,
  ember: 8,
  hull: 9,
  sail: 10,
  flag: 11,
  metal: 12,
  foliage: 13,
  smoke: 14,
  trunk: 15,
  slate: 16,
} as const

type Material = (typeof MATERIAL)[keyof typeof MATERIAL]
type Point = readonly [number, number, number]

/** A place and a turn about the vertical, applied to every shape added while it holds. */
type Frame = {x: number; y: number; z: number; turn: number}

class Mesh {
  readonly data: number[] = []
  frame: Frame = {x: 0, y: 0, z: 0, turn: 0}

  at(x: number, y: number, z: number, turn = 0): this {
    this.frame = {x, y, z, turn}
    return this
  }

  private vertex([px, py, pz]: Point, material: Material, sway: number) {
    const c = Math.cos(this.frame.turn)
    const s = Math.sin(this.frame.turn)
    this.data.push(
      this.frame.x + px * c - pz * s,
      this.frame.y + py,
      this.frame.z + px * s + pz * c,
      material,
      sway,
    )
  }

  triangle(a: Point, b: Point, c: Point, material: Material, sway: readonly [number, number, number] = [0, 0, 0]) {
    this.vertex(a, material, sway[0])
    this.vertex(b, material, sway[1])
    this.vertex(c, material, sway[2])
  }

  quad(a: Point, b: Point, c: Point, d: Point, material: Material) {
    this.triangle(a, b, c, material)
    this.triangle(a, c, d, material)
  }

  /** A box standing on (x, y, z), `w` along x, `h` up, `d` along z. */
  box(x: number, y: number, z: number, w: number, h: number, d: number, material: Material) {
    const [x0, x1, y0, y1, z0, z1] = [x - w / 2, x + w / 2, y, y + h, z - d / 2, z + d / 2]
    this.quad([x0, y1, z0], [x0, y1, z1], [x1, y1, z1], [x1, y1, z0], material)
    this.quad([x0, y0, z0], [x1, y0, z0], [x1, y0, z1], [x0, y0, z1], material)
    this.quad([x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1], material)
    this.quad([x1, y0, z0], [x0, y0, z0], [x0, y1, z0], [x1, y1, z0], material)
    this.quad([x1, y0, z1], [x1, y0, z0], [x1, y1, z0], [x1, y1, z1], material)
    this.quad([x0, y0, z0], [x0, y0, z1], [x0, y1, z1], [x0, y1, z0], material)
  }

  /** A pitched roof over a `w` by `d` box, its ridge along x, `h` tall. */
  gable(x: number, y: number, z: number, w: number, h: number, d: number, material: Material, gableMaterial: Material) {
    const [x0, x1, z0, z1] = [x - w / 2, x + w / 2, z - d / 2, z + d / 2]
    const top = y + h
    this.quad([x0, y, z1], [x1, y, z1], [x1, top, z], [x0, top, z], material)
    this.quad([x1, y, z0], [x0, y, z0], [x0, top, z], [x1, top, z], material)
    this.triangle([x1, y, z1], [x1, y, z0], [x1, top, z], gableMaterial)
    this.triangle([x0, y, z0], [x0, y, z1], [x0, top, z], gableMaterial)
  }

  /** A round column narrowing from `bottom` to `top` radius; a top of 0 is a cone. */
  column(x: number, y: number, z: number, bottom: number, top: number, h: number, sides: number, material: Material) {
    for (let i = 0; i < sides; i++) {
      const a = (i / sides) * Math.PI * 2
      const b = ((i + 1) / sides) * Math.PI * 2
      const lowA: Point = [x + Math.cos(a) * bottom, y, z + Math.sin(a) * bottom]
      const lowB: Point = [x + Math.cos(b) * bottom, y, z + Math.sin(b) * bottom]
      const highA: Point = [x + Math.cos(a) * top, y + h, z + Math.sin(a) * top]
      const highB: Point = [x + Math.cos(b) * top, y + h, z + Math.sin(b) * top]
      if (top > 0) {
        this.quad(lowA, highA, highB, lowB, material)
        this.triangle([x, y + h, z], highB, highA, material)
      } else {
        this.triangle(lowA, highA, lowB, material)
      }
    }
  }

  /** A low-poly blob: a ball of `radius` squashed to `squash` of its height. */
  blob(x: number, y: number, z: number, radius: number, squash: number, material: Material) {
    const ring = 6
    const pole = (up: number): Point => [x, y + up * radius * squash, z]
    for (let i = 0; i < ring; i++) {
      const a = (i / ring) * Math.PI * 2
      const b = ((i + 1) / ring) * Math.PI * 2
      const pa: Point = [x + Math.cos(a) * radius, y, z + Math.sin(a) * radius]
      const pb: Point = [x + Math.cos(b) * radius, y, z + Math.sin(b) * radius]
      this.triangle(pole(1), pb, pa, material)
      this.triangle(pole(-0.6), pa, pb, material)
    }
  }

  tree(x: number, z: number, y: number, size: number) {
    this.column(x, y, z, 0.05 * size, 0.04 * size, 0.22 * size, 5, MATERIAL.trunk)
    this.column(x, y + 0.18 * size, z, 0.28 * size, 0, 0.42 * size, 7, MATERIAL.foliage)
    this.column(x, y + 0.42 * size, z, 0.2 * size, 0, 0.36 * size, 7, MATERIAL.foliage)
  }

  floats(): Float32Array<ArrayBuffer> {
    return new Float32Array(this.data)
  }
}

/** Repeatable noise for island coastlines: the same harbour every visit. */
const wobble = (seed: number, angle: number): number =>
  0.5 * Math.sin(angle * 3 + seed * 1.7) + 0.3 * Math.sin(angle * 5 + seed * 4.1) + 0.2 * Math.sin(angle * 7 + seed)

/**
 * An island as rings of height around its centre: a skirt below the water, a
 * beach at the waterline, then grass (or a cliff) up to a flat top for the building.
 */
type Ring = {at: number; y: number; material: Material}

const shore = (mesh: Mesh, island: Island, seed: number, rings: readonly Ring[], top: number) => {
  const sides = 18
  const point = (ring: Ring, side: number): Point => {
    const angle = (side / sides) * Math.PI * 2
    const reach = island.radius * ring.at * (1 + 0.09 * wobble(seed + ring.at, angle))
    return [island.x + Math.cos(angle) * reach, ring.y, island.z + Math.sin(angle) * reach]
  }
  for (let r = 0; r + 1 < rings.length; r++) {
    const outer = rings[r]!
    const inner = rings[r + 1]!
    for (let side = 0; side < sides; side++) {
      mesh.quad(point(outer, side), point(inner, side), point(inner, side + 1), point(outer, side + 1), inner.material)
    }
  }
  const last = rings.at(-1)!
  for (let side = 0; side < sides; side++) {
    mesh.triangle(point(last, side), [island.x, top, island.z], point(last, side + 1), last.material)
  }
}

const lowIsland = (top: number): Ring[] => [
  {at: 1.25, y: -0.8, material: MATERIAL.sand},
  {at: 1.0, y: -0.04, material: MATERIAL.sand},
  {at: 0.86, y: 0.16, material: MATERIAL.sand},
  {at: 0.74, y: top - 0.08, material: MATERIAL.grass},
  {at: 0.5, y: top, material: MATERIAL.grass},
]

const cliffIsland = (top: number): Ring[] => [
  {at: 1.25, y: -0.8, material: MATERIAL.sand},
  {at: 1.0, y: -0.04, material: MATERIAL.sand},
  {at: 0.9, y: 0.14, material: MATERIAL.sand},
  {at: 0.82, y: top - 0.04, material: MATERIAL.rock},
  {at: 0.62, y: top, material: MATERIAL.grass},
]

const INN_TOP = 0.42
const FORGE_TOP = 0.4
const CASTLE_TOP = 0.62

const inn = (mesh: Mesh) => {
  const {x, z} = PLACES.inn
  mesh.at(x - 0.15, INN_TOP, z - 0.1, 0.35)
  // Whitewashed walls between dark timbers, a red roof and a stone chimney.
  mesh.box(0, 0, 0, 1.2, 0.62, 0.8, MATERIAL.plaster)
  for (const [px, pz] of [[-0.6, -0.4], [0.6, -0.4], [0.6, 0.4], [-0.6, 0.4], [0, 0.4], [0, -0.4]] as const) {
    mesh.box(px, 0, pz, 0.07, 0.64, 0.07, MATERIAL.wood)
  }
  mesh.box(0, 0.3, 0.405, 1.22, 0.05, 0.02, MATERIAL.wood)
  mesh.gable(0, 0.62, 0, 1.42, 0.5, 1.0, MATERIAL.roof, MATERIAL.plaster)
  mesh.box(0.38, 0.6, -0.18, 0.18, 0.62, 0.18, MATERIAL.stone)
  mesh.box(0.38, 1.22, -0.18, 0.22, 0.05, 0.22, MATERIAL.stone)
  // Windows and a door on the faces the camera sees.
  for (const px of [-0.34, 0.3]) mesh.box(px, 0.36, 0.405, 0.16, 0.14, 0.02, MATERIAL.window)
  mesh.box(-0.02, 0, 0.405, 0.18, 0.3, 0.025, MATERIAL.wood)
  for (const pz of [-0.18, 0.18]) mesh.box(0.605, 0.32, pz, 0.02, 0.14, 0.14, MATERIAL.window)
  // A hanging sign by the door.
  mesh.box(0.7, 0, 0.62, 0.04, 0.55, 0.04, MATERIAL.wood)
  mesh.box(0.7, 0.3, 0.62, 0.04, 0.2, 0.22, MATERIAL.roof)
  // A small dock out into the water, on its posts.
  mesh.at(x, 0, z, 0.35)
  mesh.box(1.75, 0.12, 0.35, 0.9, 0.05, 0.36, MATERIAL.wood)
  for (const [px, pz] of [[1.45, 0.2], [1.45, 0.5], [2.1, 0.2], [2.1, 0.5]] as const) {
    mesh.box(px, -0.3, pz, 0.06, 0.48, 0.06, MATERIAL.wood)
  }
  mesh.at(0, 0, 0)
  mesh.tree(x - 1.0, z + 0.5, INN_TOP - 0.05, 1)
  mesh.tree(x + 0.15, z - 1.1, INN_TOP - 0.06, 0.8)
  mesh.tree(x - 0.75, z - 0.75, INN_TOP - 0.04, 0.9)
}

const forge = (mesh: Mesh) => {
  const {x, z} = PLACES.forge
  mesh.at(x, FORGE_TOP, z, -0.25)
  // A stone smithy with an open lean-to, the hearth glowing under it.
  mesh.box(-0.2, 0, -0.1, 0.8, 0.5, 0.8, MATERIAL.stone)
  mesh.gable(-0.2, 0.5, -0.1, 0.92, 0.32, 0.92, MATERIAL.slate, MATERIAL.stone)
  mesh.box(0.2, 0.36, -0.1, 0.02, 0.12, 0.2, MATERIAL.window)
  for (const [px, pz] of [[0.25, 0.32], [0.75, 0.32], [0.75, -0.42]] as const) {
    mesh.box(px, 0, pz, 0.06, 0.48, 0.06, MATERIAL.wood)
  }
  mesh.quad([0.2, 0.52, 0.38], [0.82, 0.44, 0.38], [0.82, 0.44, -0.48], [0.2, 0.52, -0.48], MATERIAL.slate)
  mesh.box(0.42, 0, -0.18, 0.34, 0.18, 0.3, MATERIAL.stone)
  mesh.box(0.42, 0.18, -0.18, 0.24, 0.05, 0.2, MATERIAL.ember)
  // The anvil on its stump.
  mesh.column(0.55, 0, 0.15, 0.09, 0.08, 0.14, 6, MATERIAL.trunk)
  mesh.box(0.55, 0.14, 0.15, 0.18, 0.05, 0.08, MATERIAL.metal)
  mesh.box(0.55, 0.19, 0.15, 0.26, 0.05, 0.1, MATERIAL.metal)
  // The tall chimney the smoke leaves from.
  mesh.box(-0.42, 0, -0.38, 0.24, 1.35, 0.24, MATERIAL.stone)
  mesh.box(-0.42, 1.35, -0.38, 0.3, 0.06, 0.3, MATERIAL.stone)
  // Wood stacked for the fire.
  for (let i = 0; i < 3; i++) mesh.box(-0.05 + i * 0.04, 0.0 + i * 0.07, 0.48, 0.55 - i * 0.12, 0.07, 0.12, MATERIAL.trunk)
  mesh.at(0, 0, 0)
  mesh.tree(x + 0.85, z - 0.85, FORGE_TOP - 0.05, 0.85)
  mesh.tree(x - 0.95, z + 0.55, FORGE_TOP - 0.06, 0.75)
  mesh.blob(x - 0.9, FORGE_TOP - 0.08, z - 0.75, 0.22, 0.8, MATERIAL.rock)
}

/** The forge chimney's mouth, where the smoke starts. */
export const FORGE_SMOKE: readonly [number, number, number] = (() => {
  const {x, z} = PLACES.forge
  const turn = -0.25
  const [lx, lz] = [-0.42, -0.38]
  return [x + lx * Math.cos(turn) - lz * Math.sin(turn), FORGE_TOP + 1.42, z + lx * Math.sin(turn) + lz * Math.cos(turn)]
})()

/** The inn chimney's mouth. */
export const INN_SMOKE: readonly [number, number, number] = (() => {
  const {x, z} = PLACES.inn
  const turn = 0.35
  const [lx, lz] = [0.38, -0.18]
  return [x - 0.15 + lx * Math.cos(turn) - lz * Math.sin(turn), INN_TOP + 1.28, z - 0.1 + lx * Math.sin(turn) + lz * Math.cos(turn)]
})()

const crenels = (mesh: Mesh, x0: number, x1: number, z0: number, z1: number, y: number) => {
  const step = 0.16
  if (x1 - x0 > z1 - z0) {
    for (let px = x0 + step / 2; px < x1; px += step * 2) mesh.box(px, y, (z0 + z1) / 2, step, 0.08, z1 - z0, MATERIAL.stone)
  } else {
    for (let pz = z0 + step / 2; pz < z1; pz += step * 2) mesh.box((x0 + x1) / 2, y, pz, x1 - x0, 0.08, step, MATERIAL.stone)
  }
}

/** A walled castle: four towers, a keep, and a flag that waves in the shader. */
const castle = (mesh: Mesh) => {
  const {x, z} = PLACES.castle
  mesh.at(x, CASTLE_TOP, z, 0.12)
  const half = 0.8
  const wall = 0.16
  const height = 0.5
  // Curtain walls with a walk of crenels along each top.
  mesh.box(0, 0, half, half * 2, height, wall, MATERIAL.stone)
  mesh.box(0, 0, -half, half * 2, height, wall, MATERIAL.stone)
  mesh.box(half, 0, 0, wall, height, half * 2, MATERIAL.stone)
  mesh.box(-half, 0, 0, wall, height, half * 2, MATERIAL.stone)
  crenels(mesh, -half, half, half - wall / 2, half + wall / 2, height)
  crenels(mesh, -half, half, -half - wall / 2, -half + wall / 2, height)
  crenels(mesh, half - wall / 2, half + wall / 2, -half, half, height)
  crenels(mesh, -half - wall / 2, -half + wall / 2, -half, half, height)
  // The gate in the wall facing the camera.
  mesh.box(0.1, 0, half + 0.085, 0.3, 0.32, 0.02, MATERIAL.wood)
  mesh.box(0.1, 0.32, half + 0.08, 0.38, 0.06, 0.04, MATERIAL.stone)
  // Round towers at the corners with red caps.
  for (const [px, pz] of [[-half, -half], [half, -half], [half, half], [-half, half]] as const) {
    mesh.column(px, 0, pz, 0.24, 0.22, 0.82, 8, MATERIAL.stone)
    mesh.column(px, 0.82, pz, 0.29, 0, 0.42, 8, MATERIAL.roof)
    mesh.box(px + 0.16, 0.5, pz + 0.12, 0.02, 0.12, 0.05, MATERIAL.window)
  }
  // The keep, taller than everything, with a waving flag.
  mesh.box(-0.12, 0, -0.12, 0.7, 1.15, 0.7, MATERIAL.stone)
  crenels(mesh, -0.47, 0.23, 0.18, 0.23, 1.15)
  crenels(mesh, -0.47, 0.23, -0.47, -0.42, 1.15)
  crenels(mesh, 0.18, 0.23, -0.47, 0.23, 1.15)
  crenels(mesh, -0.47, -0.42, -0.47, 0.23, 1.15)
  for (const py of [0.42, 0.78]) {
    mesh.box(0.235, py, -0.12, 0.02, 0.16, 0.08, MATERIAL.window)
    mesh.box(-0.12, py, 0.235, 0.08, 0.16, 0.02, MATERIAL.window)
  }
  mesh.box(-0.12, 1.15, -0.12, 0.035, 0.75, 0.035, MATERIAL.wood)
  const flagLength = 0.48
  const flagTop = 1.86
  const segments = 4
  for (let i = 0; i < segments; i++) {
    const a = (i / segments) * flagLength
    const b = ((i + 1) / segments) * flagLength
    const sa = a / flagLength
    const sb = b / flagLength
    mesh.triangle([-0.12 + a, flagTop, -0.12], [-0.12 + a, flagTop - 0.28, -0.12], [-0.12 + b, flagTop - 0.28, -0.12], MATERIAL.flag, [sa, sa, sb])
    mesh.triangle([-0.12 + a, flagTop, -0.12], [-0.12 + b, flagTop - 0.28, -0.12], [-0.12 + b, flagTop, -0.12], MATERIAL.flag, [sa, sb, sb])
  }
  mesh.at(0, 0, 0)
  mesh.tree(x + 1.25, z - 0.55, CASTLE_TOP - 0.05, 0.95)
  mesh.tree(x - 1.15, z + 0.75, CASTLE_TOP - 0.06, 0.85)
  mesh.tree(x - 0.6, z - 1.25, CASTLE_TOP - 0.04, 1.05)
}

/** Every island and building: one mesh, drawn as one instance. */
export const harbourMesh = (): Float32Array<ArrayBuffer> => {
  const mesh = new Mesh()
  shore(mesh, PLACES.inn, 1, lowIsland(INN_TOP), INN_TOP)
  shore(mesh, PLACES.forge, 2, lowIsland(FORGE_TOP), FORGE_TOP)
  shore(mesh, PLACES.castle, 3, cliffIsland(CASTLE_TOP), CASTLE_TOP)
  ISLETS.forEach((islet, index) => {
    shore(mesh, islet, 7 + index, [
      {at: 1.4, y: -0.6, material: MATERIAL.sand},
      {at: 1.0, y: -0.03, material: MATERIAL.sand},
      {at: 0.7, y: 0.14, material: MATERIAL.sand},
    ], 0.18)
    mesh.blob(islet.x + 0.1, 0.08, islet.z - 0.1, islet.radius * 0.55, 0.9, MATERIAL.rock)
    mesh.blob(islet.x - 0.25, 0.06, islet.z + 0.15, islet.radius * 0.35, 0.8, MATERIAL.rock)
  })
  mesh.tree(ISLETS[0]!.x - 0.2, ISLETS[0]!.z + 0.25, 0.12, 0.7)
  inn(mesh)
  forge(mesh)
  castle(mesh)
  return mesh.floats()
}

/**
 * One ship, bow along +x, waterline at y = 0. The sail takes the agent's colour
 * and bellies in the wind; the pennant at the masthead streams back.
 */
export const shipMesh = (): Float32Array<ArrayBuffer> => {
  const mesh = new Mesh()
  const deck = 0.13
  const keel = -0.08
  const top: Point[] = [[0.48, deck, 0], [0.26, deck, 0.15], [-0.3, deck, 0.15], [-0.4, deck, 0.11], [-0.4, deck, -0.11], [-0.3, deck, -0.15], [0.26, deck, -0.15]]
  const bottom: Point[] = [[0.36, keel, 0], [0.2, keel, 0.07], [-0.26, keel, 0.07], [-0.34, keel, 0.05], [-0.34, keel, -0.05], [-0.26, keel, -0.07], [0.2, keel, -0.07]]
  for (let i = 0; i < top.length; i++) {
    const next = (i + 1) % top.length
    mesh.quad(bottom[i]!, top[i]!, top[next]!, bottom[next]!, MATERIAL.hull)
  }
  for (let i = 1; i + 1 < top.length; i++) {
    mesh.triangle(top[0]!, top[i + 1]!, top[i]!, MATERIAL.wood)
    mesh.triangle(bottom[0]!, bottom[i]!, bottom[i + 1]!, MATERIAL.hull)
  }
  // A raised stern deck with a lantern, and a mast.
  mesh.box(-0.31, deck, 0, 0.16, 0.08, 0.26, MATERIAL.hull)
  mesh.box(-0.41, deck + 0.08, 0, 0.04, 0.06, 0.04, MATERIAL.window)
  mesh.box(0.04, deck, 0, 0.035, 0.66, 0.035, MATERIAL.wood)
  mesh.box(0.04, deck + 0.16, 0, 0.03, 0.03, 0.5, MATERIAL.wood)
  // The mainsail as a 3 by 3 sheet, so it can belly in the middle.
  const rows = 3
  const sailPoint = (u: number, v: number): Point => [0.06, deck + 0.17 + v * 0.44, (u - 0.5) * (0.46 - v * 0.08)]
  const belly = (u: number, v: number) => Math.sin(Math.PI * u) * Math.sin(Math.PI * Math.min(1, v * 0.85 + 0.15))
  for (let i = 0; i < rows; i++) {
    for (let j = 0; j < rows; j++) {
      const [u0, u1, v0, v1] = [i / rows, (i + 1) / rows, j / rows, (j + 1) / rows]
      mesh.triangle(sailPoint(u0, v0), sailPoint(u1, v0), sailPoint(u1, v1), MATERIAL.sail, [belly(u0, v0), belly(u1, v0), belly(u1, v1)])
      mesh.triangle(sailPoint(u0, v0), sailPoint(u1, v1), sailPoint(u0, v1), MATERIAL.sail, [belly(u0, v0), belly(u1, v1), belly(u0, v1)])
    }
  }
  // A small jib from the masthead to the bow.
  mesh.triangle([0.08, deck + 0.6, 0], [0.08, deck + 0.08, 0], [0.46, deck + 0.04, 0], MATERIAL.sail, [0.15, 0.3, 0])
  // The pennant streams back from the masthead in the agent's colour.
  const pennantTop = deck + 0.66
  mesh.triangle([0.04, pennantTop, 0], [0.04, pennantTop - 0.07, 0], [-0.18, pennantTop - 0.035, 0], MATERIAL.flag, [0, 0, 1])
  return mesh.floats()
}

/** One puff of smoke, a small faceted ball. */
export const puffMesh = (): Float32Array<ArrayBuffer> => {
  const mesh = new Mesh()
  mesh.blob(0, 0, 0, 1, 0.9, MATERIAL.smoke)
  return mesh.floats()
}

