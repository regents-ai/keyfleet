/**
 * Draws the agent harbour with WebGPU through vgpu: the crew's chart of a sea
 * of islands, one ship for each agent. Loaded only once the harbour is really going to be shown.
 *
 * The harbour as a page's background: looking across the sea from low down,
 * the islands square to the page and the water running out to the sky.
 *
 * Each frame the ripples take their steps, the sun draws its shadow map, the
 * scene is drawn into a multisampled target, and a last pass lays it on the page
 * with the chart over it: the crew icons on their rows and the lead ship's route.
 * Every mesh is instanced; the islands and buildings are one instance, the ships
 * and the smoke one each.
 */
import {prepareShader} from "@vgpu/wgsl/prepare"
import {draw, effect, frame, geometry, init, pingPong, sampler, surface, target, uniforms, type Geometry, type Gpu} from "vgpu"
import {
  group,
  instances,
  orbitRig,
  orthographic,
  perspective,
  rigPose,
  viewMatrices,
  type CameraMatrices,
  type InstanceId,
  type Pose,
} from "vgpu/scene"
import {instanceGeometry} from "vgpu/scene/gpu"

import type {IslandRenderer} from "../canvas_island"
import {harbourMesh, puffMesh, shipMesh, smokeFrom, VERTEX_FLOATS} from "./meshes"
import {
  CIRCLE_FIRST,
  CIRCLE_GROWTH,
  CIRCLE_ROWS,
  GLYPH_COUNT,
  ICON_GAP,
  MAX_DROPS,
  MAX_MARKS,
  PALETTE,
  RIPPLE_CELLS,
  RIPPLE_REACH,
  RIPPLE_STEP,
  WATER_KEY,
  partsWgsl,
  presentWgsl,
  rippleStepWgsl,
  seaWgsl,
  shadowWgsl,
  shipShadowWgsl,
  shipWgsl,
} from "./shaders"
import {
  CRUISE_SPEED,
  LAYOUTS,
  MAX_SHIPS,
  islandsOf,
  parkFleet,
  stepFleet,
  syncFleet,
  waveHeight,
  type Agent,
  type Island,
  type Layout,
  type LayoutName,
  type Ship,
} from "./sim"

export type HarbourLook = {
  readonly night: boolean
  /** The page colour the sea fades into, as #rrggbb. */
  readonly haze: string
}

/** A ship under the pointer, and the point just above its masthead, both across the canvas from 0 to 1. */
export type ShipMark = {
  readonly id: string
  readonly u: number
  readonly v: number
}

export type HarbourRenderer = IslandRenderer & {
  setAgents(agents: readonly Agent[]): void
  setLook(look: HarbourLook): void
  /** A visitor who asked for less motion gets one composed, unmoving harbour. */
  setCalm(calm: boolean): void
  /** The ship drawn nearest a point on the canvas (0 to 1 across, 0 to 1 down), if one is there. */
  shipAt(u: number, v: number): ShipMark | null
  /** Whether an island, its buildings included, is drawn under a point on the canvas. */
  onIsland(u: number, v: number): boolean
  /** Starts a ripple on the sea under a point on the canvas. A calm harbour stays still. */
  ripple(u: number, v: number): void
}

const SHADOW_SIZE = 2048
/** The sea's middle, where the waves and ripples are drawn finely: its half-width in world units, and its cells across. */
const SEA_REACH = 22
const SEA_SEGMENTS = 132
/** How far the horizon's sea runs out, and how much longer each cell beyond the middle is than the one before. */
const HORIZON_REACH = 320
const HORIZON_GROWTH = 1.09
/**
 * The horizon's camera: its lens (degrees, top to bottom), how far it looks down
 * at the sea, and the turn that sets the islands across the page with the castle
 * at the back. The horizon sits a little over three quarters of the way up.
 */
const HORIZON_FOV = 40
const HORIZON_PITCH = (11 * Math.PI) / 180
const HORIZON_YAW = Math.PI / 4
const SHIP_SCALE = 0.95
/** Where a ship is picked from (its middle) and where its name sits (over the masthead), above the water. */
const SHIP_MIDDLE = 0.35
const SHIP_TOP = 0.95
/** How far from a ship's middle a press still picks it, in world units. */
const SHIP_REACH = 0.62
/**
 * The buildings on each island, for picking: levels above the water checked for
 * a press, and how far from the island's middle they stand.
 */
const BUILDING_LEVELS = [0.6, 1, 1.4, 1.8]
const BUILDING_REACH = 0.9
const PUFFS = {forge: 8, inn: 4}
/** The moment a calm harbour is shown at: flags and sails mid-wave. */
const STILL_TIME = 2.4
/** Longest step the ships take, so a tab coming back does not jump the fleet. */
const MAX_STEP = 1 / 20
/** How high a click lifts the water, in world units, and the most steps the ripples take in one frame. */
const DROP_HEIGHT = 0.12
const MAX_RIPPLE_STEPS = 4
/**
 * The crew icons: the space between two on a place's row and on a great circle,
 * in world units, and how fast a place's row slides round, in radians a second.
 * The great circles slide the other way, more slowly.
 */
const ICON_SPACING = 1.3
const CIRCLE_SPACING = 1.8
const ICON_DRIFT = 0.05
const CIRCLE_DRIFT = -0.02
/** Share of the icons drawn grey rather than ink. */
const ICON_GREY = 0.35

/** Where the sun shines from: it casts the hatched shade. */
const DAY_SUN = normalize([0.55, 0.9, -0.35])
const NIGHT_SUN = normalize([-0.35, 0.85, -0.45])

/** `layout` names the harbour drawn: its islands and where its buildings stand. */
export async function createHarbourRenderer(
  canvas: HTMLCanvasElement,
  size: readonly [number, number],
  onDeviceLost: () => void,
  layout: LayoutName,
): Promise<HarbourRenderer> {
  const gpu = await init()
  let disposed = false
  // Disposing the device resolves the same promise, so only a harbour still on
  // screen reports a loss.
  void gpu.lost.then(() => {
    if (!disposed) onDeviceLost()
  })
  try {
    return await build(gpu, canvas, size, LAYOUTS[layout], () => disposed, () => void (disposed = true))
  } catch (error) {
    disposed = true
    gpu.dispose()
    throw error
  }
}

async function build(
  gpu: Gpu,
  canvas: HTMLCanvasElement,
  size: readonly [number, number],
  layout: Layout,
  isDisposed: () => boolean,
  markDisposed: () => void,
): Promise<HarbourRenderer> {
  const stage = surface(gpu, canvas, {autoResize: false, alphaMode: "opaque", label: "harbour"})
  stage.resize([size[0], size[1]])

  const parts = prepareShader(partsWgsl, "harbour_parts.wgsl")
  const shipParts = prepareShader(shipWgsl, "harbour_ship.wgsl")
  const water = prepareShader(seaWgsl, "harbour_sea.wgsl")
  const shadow = prepareShader(shadowWgsl, "harbour_shadow.wgsl")
  const shipShadow = prepareShader(shipShadowWgsl, "harbour_ship_shadow.wgsl")
  const presentShader = prepareShader(presentWgsl, "harbour_present.wgsl")
  const rippleShader = prepareShader(rippleStepWgsl, "harbour_ripples.wgsl")

  // The islands and buildings never move: one instance at the origin. Its tint
  // is the castle's banner colour, the chart's one orange.
  const tint = {style: {format: "float32x4", default: [0, 0, 0, 0]}} as const
  const land = instances({capacity: 1, attributes: tint})
  land.add({style: [...PALETTE.accent, 0]})
  const fleet = instances({capacity: MAX_SHIPS, attributes: tint})
  const smoke = instances({capacity: PUFFS.forge + PUFFS.inn, attributes: tint})
  const puffIds = Array.from({length: PUFFS.forge + PUFFS.inn}, (_, index) => smoke.add({style: [0, 0, 0, index]}))

  const bridges = [
    instanceGeometry(gpu, land, {mesh: meshGeometry(gpu, harbourMesh(layout), "harbour.land")}),
    instanceGeometry(gpu, fleet, {mesh: meshGeometry(gpu, shipMesh(), "harbour.ship")}),
    instanceGeometry(gpu, smoke, {mesh: meshGeometry(gpu, puffMesh(), "harbour.smoke")}),
  ]

  const camera: {pose: Pose; projection: Float32Array; matrices: CameraMatrices} = {
    pose: {position: new Float32Array(3), quaternion: new Float32Array(4)},
    projection: new Float32Array(16),
    matrices: {view: new Float32Array(16), viewProjection: new Float32Array(16)},
  }
  // The distance is set as the harbour is framed.
  const poseAt = (distance: number) =>
    rigPose(orbitRig({target: [0, 0, 0], yaw: HORIZON_YAW, pitch: HORIZON_PITCH, distance}), camera.pose)
  poseAt(40)
  const cameraValues = {viewProjection: camera.matrices.viewProjection, toEye: normalize([...camera.pose.position])}
  /** The view's inverse, to send a point on the canvas back into the world. */
  const unview = new Float32Array(16)
  const cameraUniforms = uniforms(gpu, cameraValues)

  const islands = islandsOf(layout)
  const islandRows = new Float32Array(islands.length * 4)
  islands.forEach((island, index) => islandRows.set([island.x, island.z, island.radius, 0], index * 4))
  const shipRows = new Float32Array(MAX_SHIPS * 4)
  const sceneValues = {
    lightViewProjection: new Float32Array(16),
    sunDirection: [...DAY_SUN],
    time: STILL_TIME,
    haze: [...PALETTE.paperDay],
    night: 0,
    shipCount: 0,
    islands: rows(islandRows),
    ships: rows(shipRows),
  }
  const sceneUniforms = uniforms(gpu, sceneValues)

  const shadowTarget = target(gpu, {size: [SHADOW_SIZE, SHADOW_SIZE], format: "r8unorm", depth: "depth32float", label: "harbour.sun"})
  const sceneTarget = target(gpu, {size: [size[0], size[1]], format: "rgba8unorm", depth: true, msaa: true, label: "harbour.scene"})
  const shadowSampler = sampler(gpu, {
    compare: "less-equal",
    minFilter: "linear",
    magFilter: "linear",
    addressModeU: "clamp-to-edge",
    addressModeV: "clamp-to-edge",
  })
  const lit = {camera: cameraUniforms, scene: sceneUniforms, shadowMap: shadowTarget, shadowSampler}

  // The ripples: the sea's height a cell at a time, stepped on the GPU from one
  // target into the other.
  const field = pingPong(gpu, RIPPLE_CELLS, RIPPLE_CELLS, {format: "rgba16float", label: "harbour.ripples"})
  const rippleSampler = sampler(gpu, {
    minFilter: "linear",
    magFilter: "linear",
    addressModeU: "clamp-to-edge",
    addressModeV: "clamp-to-edge",
  })
  const dropRows = new Float32Array(MAX_DROPS * 4)
  const rippleValues = {islands: rows(islandRows), drops: rows(dropRows)}
  const rippleStep = effect(gpu, rippleShader, {set: {sea: rippleValues, field: field.read}, label: "harbour.ripples"})
  const riding = () => ({ripples: field.read, rippleSampler})

  const passes = bridges.map((bridge, index) => {
    // The fleet's bridge: only ships ride the ripples.
    const ships = bridge === bridges[1]
    return {
      bridge,
      ships,
      shadow: draw(gpu, {
        shader: ships ? shipShadow : shadow,
        geometry: bridge.geometry,
        targets: [shadowTarget],
        writeMask: [],
        depth: {bias: 2, biasSlopeScale: 2.5},
        cull: "none",
        set: ships ? {scene: sceneUniforms, ...riding()} : {scene: sceneUniforms},
        label: `harbour.shadow.${index}`,
      }),
      color: draw(gpu, {
        shader: ships ? shipParts : parts,
        geometry: bridge.geometry,
        targets: [sceneTarget],
        cull: "none",
        set: ships ? {...lit, ...riding()} : lit,
        label: `harbour.parts.${index}`,
      }),
    }
  })
  const sea = draw(gpu, {
    shader: water,
    geometry: seaGeometry(gpu, HORIZON_REACH),
    targets: [sceneTarget],
    cull: "none",
    set: {...lit, ...riding()},
    label: "harbour.sea",
  })
  const markRows = new Float32Array(MAX_MARKS * 4)
  const presentValues = {
    resolution: [size[0], size[1]],
    line: 1,
    cell: 1,
    ink: [...PALETTE.inkDay],
    time: STILL_TIME,
    paper: [...PALETTE.paperDay],
    markCount: 0,
    band: [...PALETTE.bandDay],
    leading: 0,
    lead: [0, 0],
    marks: rows(markRows),
  }
  const present = effect(gpu, presentShader, {
    set: {present: presentValues, sceneColor: sceneTarget, linearSampler: sampler(gpu, {minFilter: "linear", magFilter: "linear"})},
    label: "harbour.present",
  })
  await Promise.all([
    ...passes.flatMap(pass => [pass.shadow.compile(shadowTarget), pass.color.compile(sceneTarget)]),
    sea.compile(sceneTarget),
    present.compile(stage),
    rippleStep.compile(field.write),
  ])

  let ships: Ship[] = []
  const shipIds = new Map<string, InstanceId>()
  let time = STILL_TIME
  let night = 0
  let nightGoal = 0
  let calm = false
  let lastStep: number | undefined
  /** Seconds the ripples are owed, and the clicks waiting to land in their next step. */
  let rippleClock = 0
  let drops: [number, number][] = []
  let clear: [number, number, number, number] = [...PALETTE.paperDay, WATER_KEY]
  const world = new Float32Array(16)
  const seaHeight = (x: number, z: number) => waveHeight(x, z, time)

  /** A point in the world, across the canvas from 0 to 1, and how far in front of the camera it is. */
  const onCanvas = (x: number, y: number, z: number): [number, number, number] => {
    const m = camera.matrices.viewProjection
    const w = m[3]! * x + m[7]! * y + m[11]! * z + m[15]!
    const ndcX = (m[0]! * x + m[4]! * y + m[8]! * z + m[12]!) / w
    const ndcY = (m[1]! * x + m[5]! * y + m[9]! * z + m[13]!) / w
    return [(ndcX + 1) / 2, (1 - ndcY) / 2, w]
  }

  /** Where a point on the canvas meets the level `y` above the still sea, if it does in front of the camera. */
  const onLevel = (u: number, v: number, y: number): [number, number] | null => {
    const near = unproject(unview, u * 2 - 1, 1 - v * 2, 0)
    const far = unproject(unview, u * 2 - 1, 1 - v * 2, 1)
    const along = (y - near[1]) / (far[1] - near[1])
    if (!(along >= 0 && along <= 1)) return null
    return [near[0] + (far[0] - near[0]) * along, near[2] + (far[2] - near[2]) * along]
  }

  /** The points a frame must hold: each island's buildings and the rings its ships sail. */
  const framed = (): [number, number, number][] => [
    ...Object.values(layout.places).flatMap(island => [
      [island.x, 2.4, island.z] as [number, number, number],
      ...Array.from({length: 16}, (_, i): [number, number, number] => {
        const angle = (i / 16) * Math.PI * 2
        return [island.x + Math.cos(angle) * (island.radius + 1.9), 0, island.z + Math.sin(angle) * (island.radius + 1.9)]
      }),
    ]),
    ...layout.islets.map((islet): [number, number, number] => [islet.x, 0, islet.z]),
  ]

  const fitCamera = () => {
    fitHorizon()
    invert(camera.matrices.viewProjection, unview)
    cameraUniforms.set(cameraValues)
  }

  /**
   * The horizon: the camera backs away until every island and its rings are in
   * the frame, the rings allowed a little past the sides of a narrow one.
   */
  const fitHorizon = () => {
    const [width, height] = stage.size
    const aspect = width / height
    perspective({fov: HORIZON_FOV, near: 0.5, far: HORIZON_REACH * 2}, aspect, camera.projection)
    const across = aspect < 1.3 ? 1 / 0.84 : 0.94
    const points = framed()
    const fits = (distance: number) => {
      poseAt(distance)
      viewMatrices(camera.pose, camera.projection, camera.matrices)
      return points.every(([x, y, z]) => {
        const [u, v, w] = onCanvas(x, y, z)
        return w > 0 && Math.abs(u * 2 - 1) <= across && v <= 0.96
      })
    }
    let [low, high] = [4, 400]
    for (let step = 0; step < 24; step++) {
      const middle = (low + high) / 2
      if (fits(middle)) high = middle
      else low = middle
    }
    fits(high)
    cameraValues.toEye = normalize([...camera.pose.position])
  }

  const light = () => {
    const sun = normalize(mix3(DAY_SUN, NIGHT_SUN, night))
    sceneValues.sunDirection = sun
    sceneValues.night = night
    sceneValues.lightViewProjection.set(sunViewProjection(sun))
  }

  const placeShips = () => {
    let row = 0
    for (const ship of ships) {
      const id = shipIds.get(ship.id)!
      fleet.setWorld(id, shipWorld(ship, seaHeight, world))
      shipRows.set([ship.x, ship.z, ship.heading, Math.min(1, ship.speed / CRUISE_SPEED)], row * 4)
      row += 1
    }
    sceneValues.shipCount = row
  }

  /**
   * The crew icons, evenly round each place's row and each great circle and
   * sliding slowly along it, and the lead ship, all in the canvas's pixels. An
   * icon behind the camera or off the canvas is left out; the present pass
   * hides the ones behind land.
   */
  const iconRow = (x: number, z: number, radius: number, spacing: number, drift: number) => {
    const count = Math.round((Math.PI * 2 * radius) / spacing)
    return Array.from({length: count}, (_, slot) => ({x, z, radius, drift, angle: (slot / count) * Math.PI * 2}))
  }
  const icons = [
    ...Object.values(layout.places).flatMap(island => iconRow(island.x, island.z, island.radius + ICON_GAP, ICON_SPACING, ICON_DRIFT)),
    ...Array.from({length: CIRCLE_ROWS}, (_, row) => iconRow(0, 0, CIRCLE_FIRST * CIRCLE_GROWTH ** row, CIRCLE_SPACING, CIRCLE_DRIFT)).flat(),
  ]
  const placeMarks = () => {
    const [width, height] = stage.size
    let count = 0
    icons.forEach(({x: middleX, z: middleZ, radius, drift, angle}, index) => {
      if (count === MAX_MARKS) return
      const turned = angle + time * drift
      const x = middleX + Math.cos(turned) * radius
      const z = middleZ + Math.sin(turned) * radius
      const [u, v, w] = onCanvas(x, seaHeight(x, z), z)
      if (w <= 0 || u < -0.05 || u > 1.05 || v < -0.05 || v > 1.05) return
      const pick = unit(index * 12.9898)
      markRows.set([u * width, v * height, Math.floor(pick * GLYPH_COUNT), unit(index * 78.233) < ICON_GREY ? 1 : 0], count * 4)
      count += 1
    })
    presentValues.markCount = count
    const lead = ships[0]
    const [u, v, w] = lead ? onCanvas(lead.x, seaHeight(lead.x, lead.z) + SHIP_MIDDLE, lead.z) : [0, 0, 0]
    presentValues.leading = w > 0 ? 1 : 0
    presentValues.lead = [u * width, v * height]
  }

  const chimneys = smokeFrom(layout)
  const placeSmoke = () => {
    puffIds.forEach((id, index) => {
      const fromForge = index < PUFFS.forge
      const count = fromForge ? PUFFS.forge : PUFFS.inn
      const slot = fromForge ? index : index - PUFFS.forge
      const [x, y, z] = fromForge ? chimneys.forge : chimneys.inn
      const age = fract(time * (fromForge ? 0.16 : 0.12) + slot / count)
      const size = (fromForge ? 0.07 + 0.2 * age : 0.05 + 0.12 * age) * (1 - smoothstep(0.7, 1, age))
      const drift = Math.sin(time * 0.7 + slot * 2.1) * 0.06 * age
      world.fill(0)
      world[0] = size
      world[5] = size
      world[10] = size
      world[12] = x + age * 0.75 + drift
      world[13] = y + age * (fromForge ? 1.5 : 1.0)
      world[14] = z - age * 0.45 + drift
      world[15] = 1
      smoke.setWorld(id, world)
    })
  }

  /** Moves the ripples on by the steps they are owed. Each step is its own submission, so it sees its own drops. */
  const stepRipples = () => {
    for (let steps = 0; steps < MAX_RIPPLE_STEPS && rippleClock >= RIPPLE_STEP; steps++) {
      dropRows.fill(0)
      drops.forEach(([x, z], index) => dropRows.set([x, z, DROP_HEIGHT, 0], index * 4))
      drops = []
      rippleStep.set({sea: rippleValues, field: field.read})
      frame(gpu, current => current.pass(field.write, rippleStep))
      field.swap()
      rippleClock -= RIPPLE_STEP
    }
    // A slow frame drops the time it could not catch up on rather than carrying it.
    rippleClock = Math.min(rippleClock, RIPPLE_STEP)
  }

  /** Flattens the sea, for a calm harbour. */
  const stillRipples = () => {
    drops = []
    rippleClock = 0
    frame(gpu, current => {
      current.pass({target: field.read, clear: [0, 0, 0, 0]}, () => {})
      current.pass({target: field.write, clear: [0, 0, 0, 0]}, () => {})
    })
  }

  const renderer: HarbourRenderer = {
    setAgents(agents) {
      const next = syncFleet(layout, ships, agents)
      for (const ship of ships) {
        if (next.includes(ship)) continue
        fleet.remove(shipIds.get(ship.id)!)
        shipIds.delete(ship.id)
      }
      next.forEach((ship, index) => {
        const colour = [...displayColor(ship.color), index * 1.37] as const
        const id = shipIds.get(ship.id)
        if (id === undefined) shipIds.set(ship.id, fleet.add({style: colour}))
        else fleet.set(id, {style: colour})
      })
      ships = next
      if (calm) parkFleet(layout, ships)
    },
    setLook(look) {
      nightGoal = look.night ? 1 : 0
      const haze = displayColor(look.haze)
      sceneValues.haze = haze
      clear = [haze[0], haze[1], haze[2], WATER_KEY]
      if (calm || lastStep === undefined) {
        night = nightGoal
        light()
      }
    },
    setCalm(next) {
      calm = next
      if (!calm) return
      time = STILL_TIME
      night = nightGoal
      light()
      parkFleet(layout, ships)
      stillRipples()
    },
    shipAt(u, v) {
      let nearest: Ship | undefined
      let nearestMiss = 1
      for (const ship of ships) {
        const [shipU, shipV, w] = onCanvas(ship.x, seaHeight(ship.x, ship.z) + SHIP_MIDDLE, ship.z)
        // The reach as a share of the canvas, across and down, at the ship's distance.
        const reachU = (SHIP_REACH * Math.abs(camera.projection[0]!)) / (2 * w)
        const reachV = (SHIP_REACH * Math.abs(camera.projection[5]!)) / (2 * w)
        const miss = ((u - shipU) / reachU) ** 2 + ((v - shipV) / reachV) ** 2
        if (miss < nearestMiss) {
          nearest = ship
          nearestMiss = miss
        }
      }
      if (!nearest) return null
      const [markU, markV] = onCanvas(nearest.x, seaHeight(nearest.x, nearest.z) + SHIP_TOP, nearest.z)
      return {id: nearest.id, u: markU, v: markV}
    },
    onIsland(u, v) {
      const near = (island: Island, y: number, reach: number) => {
        const hit = onLevel(u, v, y)
        return hit !== null && Math.hypot(hit[0] - island.x, hit[1] - island.z) < reach
      }
      return Object.values(layout.places).some(
        island => near(island, 0, island.radius) || BUILDING_LEVELS.some(y => near(island, y, BUILDING_REACH)),
      )
    },
    ripple(u, v) {
      if (calm) return
      const hit = onLevel(u, v, 0)
      if (!hit) return
      const [x, z] = hit
      if (Math.max(Math.abs(x), Math.abs(z)) > RIPPLE_REACH - 1) return
      drops = [...drops, [x, z] as [number, number]].slice(-MAX_DROPS)
    },
    resize(width, height) {
      stage.resize([width, height])
      sceneTarget.resize([width, height])
      presentValues.resolution = [width, height]
      // Outlines and icons keep the same size on the page at any resolution.
      presentValues.line = Math.max(1, height / 640)
      presentValues.cell = Math.max(1, Math.round(Math.min(width, height) / 420))
      present.set({present: presentValues})
      fitCamera()
    },
    step() {
      if (calm) return false
      const now = performance.now() / 1000
      const dt = lastStep === undefined ? 0 : Math.min(MAX_STEP, now - lastStep)
      lastStep = now
      time += dt
      rippleClock += dt
      stepFleet(layout, ships, dt)
      if (night !== nightGoal) {
        night += (nightGoal - night) * Math.min(1, dt * 2.5)
        if (Math.abs(night - nightGoal) < 0.002) night = nightGoal
        light()
      }
      return true
    },
    present() {
      sceneValues.time = time
      placeShips()
      placeSmoke()
      sceneUniforms.set(sceneValues)
      const counts = passes.map(pass => pass.bridge.publish())
      presentValues.time = time
      presentValues.ink = mix3(PALETTE.inkDay, PALETTE.inkNight, night)
      presentValues.paper = mix3(PALETTE.paperDay, PALETTE.paperNight, night)
      presentValues.band = mix3(PALETTE.bandDay, PALETTE.bandNight, night)
      placeMarks()
      present.set({present: presentValues})
      stepRipples()
      const ripples = riding()
      sea.set(ripples)
      for (const pass of passes) {
        if (!pass.ships) continue
        pass.shadow.set(ripples)
        pass.color.set(ripples)
      }
      frame(gpu, current => {
        current.pass({target: shadowTarget, clear: [0, 0, 0, 0]}, pass => {
          passes.forEach((each, index) => {
            if (counts[index]! > 0) pass.draw(each.shadow, {instances: counts[index]})
          })
        })
        current.pass({target: sceneTarget, clear}, pass => {
          passes.forEach((each, index) => {
            if (counts[index]! > 0) pass.draw(each.color, {instances: counts[index]})
          })
          pass.draw(sea)
        })
        current.pass(stage, present)
      })
    },
    settled() {
      return gpu.settled()
    },
    dispose() {
      if (isDisposed()) return
      markDisposed()
      for (const bridge of bridges) bridge.destroy()
      stage.dispose()
      gpu.dispose()
    },
  }

  fitCamera()
  light()
  return renderer
}

function meshGeometry(gpu: Gpu, vertices: Float32Array<ArrayBuffer>, label: string): Geometry {
  return geometry(gpu, {
    buffers: [
      {
        data: vertices,
        stride: VERTEX_FLOATS * 4,
        attributes: {
          position: {format: "float32x3", offset: 0, location: 0},
          material: {format: "float32", offset: 12, location: 1},
          sway: {format: "float32", offset: 16, location: 2},
        },
      },
    ],
    vertexCount: vertices.length / VERTEX_FLOATS,
    label,
  })
}

/**
 * A square of sea, centred on the harbour, flat until the shader lifts it: fine
 * cells across the middle, and beyond it, out to `reach`, cells each a little
 * longer than the last.
 */
function seaGeometry(gpu: Gpu, reach: number): Geometry {
  const middle = Array.from({length: SEA_SEGMENTS + 1}, (_, index) => (index / SEA_SEGMENTS - 0.5) * SEA_REACH * 2)
  const beyond: number[] = []
  for (let cell = (SEA_REACH * 2) / SEA_SEGMENTS, at = SEA_REACH; at < reach; ) {
    cell *= HORIZON_GROWTH
    at = Math.min(reach, at + cell)
    beyond.push(at)
  }
  const lines = [...beyond.map(at => -at).reverse(), ...middle, ...beyond]
  const side = lines.length
  const positions = new Float32Array(side * side * 3)
  for (let row = 0; row < side; row++) {
    for (let column = 0; column < side; column++) {
      const at = (row * side + column) * 3
      positions[at] = lines[column]!
      positions[at + 2] = lines[row]!
    }
  }
  const cells = side - 1
  const indices = new Uint32Array(cells * cells * 6)
  let at = 0
  for (let row = 0; row < cells; row++) {
    for (let column = 0; column < cells; column++) {
      const a = row * side + column
      indices.set([a, a + side, a + 1, a + 1, a + side, a + side + 1], at)
      at += 6
    }
  }
  return geometry(gpu, {
    buffers: [{data: positions, stride: 12, attributes: {position: {format: "float32x3", offset: 0, location: 0}}}],
    indices,
    label: "harbour.sea",
  })
}

/** A ship riding the swell under it: pitched by the swell and heeled into its turn. The shaders add the ripples. */
function shipWorld(ship: Ship, height: (x: number, z: number) => number, out: Float32Array): Float32Array {
  const fx = Math.cos(ship.heading)
  const fz = Math.sin(ship.heading)
  const y = height(ship.x, ship.z)
  const along = (height(ship.x + fx * 0.3, ship.z + fz * 0.3) - height(ship.x - fx * 0.3, ship.z - fz * 0.3)) / 0.6
  const across = (height(ship.x - fz * 0.2, ship.z + fx * 0.2) - height(ship.x + fz * 0.2, ship.z - fx * 0.2)) / 0.4
  const pitch = Math.atan(along) * 0.9
  const roll = Math.atan(across) * 0.9 - ship.turn * ship.speed * 0.5
  // Bow along heading, mast up, beam across; then pitch about the beam and roll about the keel.
  let forward = [fx, 0, fz]
  let up = [0, 1, 0]
  let beam = [-fz, 0, fx]
  ;[forward, up] = [add(scale(forward, Math.cos(pitch)), scale(up, Math.sin(pitch))), add(scale(up, Math.cos(pitch)), scale(forward, -Math.sin(pitch)))]
  ;[up, beam] = [add(scale(up, Math.cos(roll)), scale(beam, Math.sin(roll))), add(scale(beam, Math.cos(roll)), scale(up, -Math.sin(roll)))]
  out.set([...scale(forward, SHIP_SCALE), 0, ...scale(up, SHIP_SCALE), 0, ...scale(beam, SHIP_SCALE), 0, ship.x, y, ship.z, 1])
  return out
}

/** The sun's orthographic view over the whole harbour. */
function sunViewProjection(sun: readonly number[]): Float32Array {
  const distance = 30
  const node = group({position: [sun[0]! * distance, sun[1]! * distance, sun[2]! * distance]}).lookAt([0, 0, 0])
  const pose: Pose = {position: new Float32Array(node.worldPosition), quaternion: new Float32Array(node.quaternion)}
  const reach = 12.5
  const projection = orthographic(
    {left: -reach, right: reach, bottom: -reach, top: reach, near: distance - 16, far: distance + 16},
    new Float32Array(16),
  )
  const matrices: CameraMatrices = {view: new Float32Array(16), viewProjection: new Float32Array(16)}
  viewMatrices(pose, projection, matrices)
  return matrices.viewProjection
}

/** The inverse of a 4x4 matrix, columns first. */
function invert(m: Float32Array, out: Float32Array): Float32Array {
  const [a00, a01, a02, a03, a10, a11, a12, a13, a20, a21, a22, a23, a30, a31, a32, a33] = m
  const b00 = a00 * a11 - a01 * a10
  const b01 = a00 * a12 - a02 * a10
  const b02 = a00 * a13 - a03 * a10
  const b03 = a01 * a12 - a02 * a11
  const b04 = a01 * a13 - a03 * a11
  const b05 = a02 * a13 - a03 * a12
  const b06 = a20 * a31 - a21 * a30
  const b07 = a20 * a32 - a22 * a30
  const b08 = a20 * a33 - a23 * a30
  const b09 = a21 * a32 - a22 * a31
  const b10 = a21 * a33 - a23 * a31
  const b11 = a22 * a33 - a23 * a32
  const det = 1 / (b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06)
  out.set([
    (a11 * b11 - a12 * b10 + a13 * b09) * det,
    (a02 * b10 - a01 * b11 - a03 * b09) * det,
    (a31 * b05 - a32 * b04 + a33 * b03) * det,
    (a22 * b04 - a21 * b05 - a23 * b03) * det,
    (a12 * b08 - a10 * b11 - a13 * b07) * det,
    (a00 * b11 - a02 * b08 + a03 * b07) * det,
    (a32 * b02 - a30 * b05 - a33 * b01) * det,
    (a20 * b05 - a22 * b02 + a23 * b01) * det,
    (a10 * b10 - a11 * b08 + a13 * b06) * det,
    (a01 * b08 - a00 * b10 - a03 * b06) * det,
    (a30 * b04 - a31 * b02 + a33 * b00) * det,
    (a21 * b02 - a20 * b04 - a23 * b00) * det,
    (a11 * b07 - a10 * b09 - a12 * b06) * det,
    (a00 * b09 - a01 * b07 + a02 * b06) * det,
    (a31 * b01 - a30 * b03 - a32 * b00) * det,
    (a20 * b03 - a21 * b01 + a22 * b00) * det,
  ])
  return out
}

/** A point of the canvas, at a depth from 0 (near) to 1 (far), back in the world. */
function unproject(inverse: Float32Array, x: number, y: number, z: number): [number, number, number] {
  const m = inverse
  const w = m[3]! * x + m[7]! * y + m[11]! * z + m[15]!
  return [
    (m[0]! * x + m[4]! * y + m[8]! * z + m[12]!) / w,
    (m[1]! * x + m[5]! * y + m[9]! * z + m[13]!) / w,
    (m[2]! * x + m[6]! * y + m[10]! * z + m[14]!) / w,
  ]
}

/** Views onto a packed array, one per vec4 row of a uniform array. */
function rows(packed: Float32Array): Float32Array[] {
  return Array.from({length: packed.length / 4}, (_, index) => packed.subarray(index * 4, index * 4 + 4))
}

/** #rrggbb as the page shows it. */
function displayColor(hex: string): [number, number, number] {
  const value = Number.parseInt(hex.slice(1), 16)
  return [((value >> 16) & 255) / 255, ((value >> 8) & 255) / 255, (value & 255) / 255]
}

function normalize(vector: readonly number[]): [number, number, number] {
  const length = Math.hypot(vector[0]!, vector[1]!, vector[2]!)
  return [vector[0]! / length, vector[1]! / length, vector[2]! / length]
}

function mix3(a: readonly number[], b: readonly number[], t: number): [number, number, number] {
  return [a[0]! + (b[0]! - a[0]!) * t, a[1]! + (b[1]! - a[1]!) * t, a[2]! + (b[2]! - a[2]!) * t]
}

function scale(vector: readonly number[], by: number): number[] {
  return vector.map(value => value * by)
}

function add(a: readonly number[], b: readonly number[]): number[] {
  return a.map((value, index) => value + b[index]!)
}

function fract(value: number): number {
  return value - Math.floor(value)
}

/** A fixed number from 0 to 1 for a seed, the same one every time. */
function unit(seed: number): number {
  return fract(Math.sin(seed) * 43758.5453)
}

function smoothstep(edge0: number, edge1: number, value: number): number {
  const t = Math.min(1, Math.max(0, (value - edge0) / (edge1 - edge0)))
  return t * t * (3 - 2 * t)
}
