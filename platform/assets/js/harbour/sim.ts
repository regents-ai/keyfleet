/**
 * Where the ships are. Each ship is one agent: it sails to the island of its
 * last action and circles it until the agent does something else.
 *
 * Pure numbers, no GPU: the renderer asks for a step and reads the ships back.
 */

export type Place = "inn" | "forge" | "castle"

/** One agent as the page hands it over: who, where its last action was, and its colour. */
export type Agent = {
  readonly id: string
  readonly place: Place
  readonly color: string
}

/** An island on the sea, in world units. The three places, plus two rocks to sail around. */
export type Island = {
  readonly x: number
  readonly z: number
  readonly radius: number
}

export const PLACES: Readonly<Record<Place, Island>> = {
  castle: {x: -3.45, z: -3.45, radius: 2.2},
  inn: {x: -2.0, z: 4.9, radius: 1.8},
  forge: {x: 4.6, z: -2.3, radius: 1.7},
}

export const ISLETS: readonly Island[] = [
  {x: 4.6, z: 4.4, radius: 0.7},
  {x: -7.4, z: 0.6, radius: 0.55},
]

export const ISLANDS: readonly Island[] = [PLACES.castle, PLACES.inn, PLACES.forge, ...ISLETS]

/** Ships the page will ever draw. */
export const MAX_SHIPS = 16

export type Ship = {
  readonly id: string
  place: Place
  color: string
  x: number
  z: number
  /** Direction of travel: (cos heading, sin heading) on the sea. */
  heading: number
  speed: number
  /** Radians per second the ship is turning, for the heel. */
  turn: number
  /** Which ring around its island it keeps to. */
  lane: number
}

const RING = 0.85
const LANE = 0.5
const CRUISE = 0.62
const CIRCLE = 0.32
const MAX_TURN = 0.75
const LEAD = 0.55
const CLEARANCE = 0.55
const SHORE = 0.3
const PERSONAL_SPACE = 0.95

export const orbitRadius = (ship: Ship): number => PLACES[ship.place].radius + RING + ship.lane * LANE

const wrapAngle = (angle: number): number => Math.atan2(Math.sin(angle), Math.cos(angle))

const clamp = (value: number, low: number, high: number): number => Math.min(high, Math.max(low, value))

const smoothstep = (edge0: number, edge1: number, value: number): number => {
  const t = clamp((value - edge0) / (edge1 - edge0), 0, 1)
  return t * t * (3 - 2 * t)
}

/** Ships at one island take turns between the inner and outer ring, in page order. */
const assignLanes = (ships: readonly Ship[]) => {
  const seen: Record<Place, number> = {inn: 0, forge: 0, castle: 0}
  for (const ship of ships) ship.lane = seen[ship.place]++ % 2
}

/** Puts every ship on its ring, spread evenly around its island, sailing along it. */
export const parkFleet = (ships: readonly Ship[]) => {
  const counts: Record<Place, number> = {inn: 0, forge: 0, castle: 0}
  for (const ship of ships) counts[ship.place] += 1
  const placed: Record<Place, number> = {inn: 0, forge: 0, castle: 0}
  for (const ship of ships) {
    const island = PLACES[ship.place]
    const angle = 4.3 + (placed[ship.place]++ / counts[ship.place]) * Math.PI * 2
    const radius = orbitRadius(ship) * Math.cos(LEAD / 2)
    ship.x = island.x + Math.cos(angle) * radius
    ship.z = island.z + Math.sin(angle) * radius
    ship.heading = angle + Math.PI / 2
    ship.speed = CIRCLE
    ship.turn = 0
  }
}

/**
 * Brings the fleet in line with the agents: a new agent gets a ship already
 * circling its island, a ship whose agent is gone leaves, and a ship whose agent
 * acted somewhere new turns for that island.
 */
export const syncFleet = (ships: Ship[], agents: readonly Agent[]): Ship[] => {
  const byId = new Map(ships.map(ship => [ship.id, ship]))
  const arriving: Ship[] = []
  const next = agents.slice(0, MAX_SHIPS).map(agent => {
    const ship = byId.get(agent.id)
    if (ship) {
      ship.place = agent.place
      ship.color = agent.color
      return ship
    }
    const fresh: Ship = {...agent, x: 0, z: 0, heading: 0, speed: CIRCLE, turn: 0, lane: 0}
    arriving.push(fresh)
    return fresh
  })
  assignLanes(next)
  parkFleet(arriving)
  return next
}

/** Moves every ship on by `dt` seconds. */
export const stepFleet = (ships: readonly Ship[], dt: number) => {
  for (const ship of ships) {
    const island = PLACES[ship.place]
    const radius = orbitRadius(ship)
    const dx = ship.x - island.x
    const dz = ship.z - island.z
    const distance = Math.hypot(dx, dz)

    // Chase a point a little way ahead on the ring: from far off that reads as
    // sailing for the island, and close in it bends the course into a circle.
    const around = Math.atan2(dz, dx) + (distance > radius + 2 ? 0.9 : LEAD)
    let wantX = island.x + Math.cos(around) * radius - ship.x
    let wantZ = island.z + Math.sin(around) * radius - ship.z
    const reach = Math.hypot(wantX, wantZ) || 1
    wantX /= reach
    wantZ /= reach

    for (const rock of ISLANDS) {
      const ax = ship.x - rock.x
      const az = ship.z - rock.z
      const away = Math.hypot(ax, az) || 1
      // Other islands are given a wide berth; its own only keeps it off the beach.
      const push = rock === island
        ? 1 - (away - rock.radius - SHORE) / SHORE
        : 1 - (away - rock.radius - CLEARANCE) / 1.3
      if (push <= 0) continue
      wantX += (ax / away) * Math.min(push, 1.6) * 1.6
      wantZ += (az / away) * Math.min(push, 1.6) * 1.6
    }

    for (const other of ships) {
      if (other === ship) continue
      const ax = ship.x - other.x
      const az = ship.z - other.z
      const away = Math.hypot(ax, az)
      if (away >= PERSONAL_SPACE || away === 0) continue
      wantX += (ax / away) * (PERSONAL_SPACE - away) * 1.4
      wantZ += (az / away) * (PERSONAL_SPACE - away) * 1.4
    }

    const miss = wrapAngle(Math.atan2(wantZ, wantX) - ship.heading)
    const turn = clamp(miss * 1.4, -MAX_TURN, MAX_TURN)
    ship.turn += (turn - ship.turn) * Math.min(1, dt * 2)
    ship.heading = wrapAngle(ship.heading + ship.turn * dt)

    const cruise = CIRCLE + (CRUISE - CIRCLE) * smoothstep(radius + 0.4, radius + 3, distance)
    const target = cruise * (1 - 0.45 * Math.min(1, Math.abs(miss)))
    ship.speed += (target - ship.speed) * Math.min(1, dt * 0.8)
    ship.x += Math.cos(ship.heading) * ship.speed * dt
    ship.z += Math.sin(ship.heading) * ship.speed * dt
  }
}

/**
 * The swell's height. The water shader runs the same sum, so a ship rides the
 * wave the visitor sees under it; the shaders add the ripples on top.
 */
export const waveHeight = (x: number, z: number, time: number): number =>
  0.045 * Math.sin(0.9 * x + 0.6 * z + 1.1 * time) +
  0.03 * Math.sin(-0.5 * x + 1.3 * z + 1.7 * time + 1.3) +
  0.018 * Math.sin(1.9 * x - 1.1 * z + 2.3 * time)

/** Fastest a ship sails, for the wake's strength. */
export const CRUISE_SPEED = CRUISE
