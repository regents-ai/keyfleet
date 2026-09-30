import {describe, expect, it} from "vitest"

import {buildMap, type KeyMapGrid} from "../js/hooks/key_map/layouts"
import {
  applyPatch,
  availableKey,
  decodeSnapshot,
  describeKey,
  drawnKeys,
  hasBit,
  keyMarks,
  keyNear,
  levelHeading,
  levelSale,
  levelTone,
  lastChoosable,
  nextHeldKey,
  onSaleLevel,
  type KeyMapState,
} from "../js/hooks/key_map/state"
import {levelEdges} from "../js/hooks/key_map/tiles"

describe("key map cursor search", () => {
  it("finds the nearest key, or nothing on a map without keys", () => {
    const grid = buildMap("accelerant", 2_000)
    const home = grid.home(1_000)
    expect(keyNear(grid, home)).toEqual(home)
    const found = keyNear(grid, [home[0] + 40, home[1]])!
    expect(grid.valueAt(...found)).toBeGreaterThan(0)

    const empty: KeyMapGrid = {...grid, valueAt: () => 0}
    expect(keyNear(empty, [3, 4])).toBeNull()
  })
})

const bits = (...keys: number[]) => {
  const bytes = new Uint8Array(250)
  for (const key of keys) bytes[(key - 1) >> 3] |= 1 << ((key - 1) & 7)
  return bytes
}

const fibonacci = (minted: number): KeyMapState => ({
  minted,
  maxSupply: null,
  mine: new Uint8Array(0),
  agent: new Uint8Array(0),
})

const classic = (minted: number): KeyMapState => ({
  minted,
  maxSupply: 1_024,
  mine: new Uint8Array(0),
  agent: new Uint8Array(0),
})

const accelerant = (minted: number, mine: Uint8Array, agent = bits()): KeyMapState => ({
  minted,
  maxSupply: 2_000,
  mine,
  agent,
})

describe("key map loading", () => {
  // The page's bitset for keys 2 and 10 (KeyMap.bitset([2, 10]) in
  // test/keyfleet_web/live/key_map_test.exs), and for no keys at all.
  it("reads the page's bitsets key by key", () => {
    const state = decodeSnapshot({minted: 10, max_supply: 1_024, mine: "AgI=", agent: ""})

    expect(state.maxSupply).toBe(1_024)
    const keys = Array.from({length: 20}, (_, i) => i + 1)
    expect(keys.filter(key => hasBit(state.mine, key))).toEqual([2, 10])
    expect(keys.filter(key => hasBit(state.agent, key))).toEqual([])
  })

  it("reads a fleet whose levels keep opening as having no size", () => {
    expect(decodeSnapshot({minted: 3, max_supply: null, mine: "", agent: ""}).maxSupply).toBeNull()
  })
})

describe("key map changes", () => {
  it("sets and clears each changed key's marks and leaves the rest", () => {
    const before = accelerant(10, bits(3, 9), bits(4))
    const after = applyPatch(before, {minted: 12, keys: [[3, 0], [4, 1], [11, 2], [12, 3]]})

    expect(after.minted).toBe(12)
    expect([3, 4, 9, 11, 12].map(key => hasBit(after.mine, key))).toEqual([false, true, true, false, true])
    expect([3, 4, 9, 11, 12].map(key => hasBit(after.agent, key))).toEqual([false, false, false, true, true])
    // The state given is left as it was.
    expect(hasBit(before.mine, 3)).toBe(true)
    expect(before.minted).toBe(10)
  })

  it("marks a key past the end of the marks it was loaded with", () => {
    const before = fibonacci(4)
    const after = applyPatch(before, {minted: 6, keys: [[6, 3]]})

    expect([hasBit(after.mine, 6), hasBit(after.agent, 6)]).toEqual([true, true])
    expect(before.mine.length).toBe(0)
  })
})

describe("key map controls", () => {
  it("steps through your keys and comes back round to the first", () => {
    const state = accelerant(20, bits(5, 12, 20))
    expect(nextHeldKey(state, 0)).toBe(5)
    expect(nextHeldKey(state, 5)).toBe(12)
    expect(nextHeldKey(state, 12)).toBe(20)
    expect(nextHeldKey(state, 20)).toBe(5)
    expect(nextHeldKey(accelerant(20, bits()), 7)).toBe(0)
  })

  it("never goes to a key of yours past the available key", () => {
    expect(nextHeldKey(accelerant(20, bits(30)), 0)).toBe(0)
  })
})

describe("key map levels", () => {
  it("steps each level through the tones in order, so neighbouring levels differ", () => {
    const tones = Array.from({length: 20}, (_, index) => levelTone(index + 1))
    expect(tones.slice(0, 6)).toEqual([0, 1, 2, 3, 0, 1])
    tones.slice(1).forEach((tone, index) => expect(tone).not.toBe(tones[index]))
  })

  // Level 7 is keys 53 to 86 and level 8 keys 87 to 141.
  it("sells the level of the available key, and moves on when that level sells out", () => {
    const grid = buildMap("fibonacci", drawnKeys("fibonacci", fibonacci(141)))
    expect(onSaleLevel(grid, fibonacci(60))).toBe(7)
    expect(onSaleLevel(grid, fibonacci(85))).toBe(7)
    expect(onSaleLevel(grid, fibonacci(86))).toBe(8)

    expect([6, 7].map(level => levelSale(7, level))).toEqual(["sold-out", "on-sale"])
    expect(levelHeading(3, "sold-out")).toBe("Level 3 · sold out")
    expect(levelHeading(7, "on-sale")).toBe("Level 7 · on sale now")
  })

  it("draws the keys sold and the rest of the level on sale, and no level after it", () => {
    expect(drawnKeys("fibonacci", fibonacci(60))).toBe(86)
    expect(drawnKeys("fibonacci", fibonacci(86))).toBe(141)
    expect(drawnKeys("fibonacci", fibonacci(0))).toBe(2)
    expect(drawnKeys("fibonacci", fibonacci(17_768))).toBe(28_654)
    // The levels never end, so a level past 20 opens once 20 is sold.
    expect(drawnKeys("fibonacci", fibonacci(46_365))).toBe(75_022)
    // Accelerant is drawn whole.
    expect(drawnKeys("accelerant", accelerant(10, bits()))).toBe(2_000)
  })

  it("draws Classic's pyramid to three rows below the row on sale, and whole once sold out", () => {
    // Nothing sold: key 1 of row 1 is on sale, so rows 1 to 4 are drawn.
    expect(drawnKeys("classic", classic(0))).toBe(10)
    // Key 5 of row 3 is on sale, so rows 1 to 6 are drawn.
    expect(drawnKeys("classic", classic(4))).toBe(21)
    expect(drawnKeys("classic", classic(5))).toBe(21)
    expect(drawnKeys("classic", classic(6))).toBe(28)
    // Row 45 is the last, so the pyramid is drawn whole once row 42 is on sale.
    expect(drawnKeys("classic", classic(860))).toBe(990)
    expect(drawnKeys("classic", classic(861))).toBe(1_024)
    expect(drawnKeys("classic", classic(1_024))).toBe(1_024)
  })

  it("never runs out of keys to sell in a fleet whose levels keep opening", () => {
    expect(availableKey(fibonacci(46_365))).toBe(46_366)
    expect(lastChoosable(fibonacci(46_365))).toBe(46_366)
    expect(availableKey(accelerant(2_000, bits()))).toBe(0)
    expect(lastChoosable(accelerant(2_000, bits()))).toBe(2_000)
  })

  it("marks keys not sold yet, other than the available one, and says so", () => {
    const state = fibonacci(60)
    const grid = buildMap("fibonacci", drawnKeys("fibonacci", state))
    expect([60, 61, 62, 80].map(key => keyMarks(state, key, 0, 0))).toEqual(["", "available", "unsold", "unsold"])
    expect(describeKey(grid, state, 80)).toBe("Key 80, level 7, not sold yet.")
  })

  // Level 1 is one row of two keys; level 8 is a 28-key row over a 27-key row.
  it("outlines a level only along its own edge", () => {
    const grid = buildMap("fibonacci", 141)
    const edgesOf = (key: number) => levelEdges(grid, ...grid.home(key), grid.levelOf(key))
    // Key 1 borders key 2 on its right and nothing else of level 1.
    expect(edgesOf(1)).toBe(0b111101)
    expect(edgesOf(2)).toBe(0b101111)
    // Level 8's second key sits on the top edge of its band, with neighbours
    // of its own level beside and below it.
    expect(edgesOf(88)).toBe(0b100001)
  })
})
