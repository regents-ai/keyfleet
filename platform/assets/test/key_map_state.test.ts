import {describe, expect, it} from "vitest"

import {buildMap, fibonacciLevelSupplies, type KeyMapGrid} from "../js/hooks/key_map/layouts"
import {
  applyPatch,
  decodeSnapshot,
  describeKey,
  drawnKeys,
  fibonacciLevelOf,
  hasBit,
  keyMarks,
  keyNear,
  levelHeading,
  levelSale,
  levelStart,
  levelTone,
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

const accelerant = (minted: number, mine: Uint8Array, agent = bits()): KeyMapState => ({
  minted,
  maxSupply: 2_000,
  mine,
  agent,
})

describe("key map loading", () => {
  // The page's bitset for keys 2 and 10 of 10 (KeyMap.bitset(10, [2, 10]) in
  // test/keyfleet_web/live/key_map_test.exs).
  it("reads the page's bitsets key by key", () => {
    const state = decodeSnapshot({minted: 10, max_supply: 10, mine: "AgI=", agent: "AAA="})

    expect(state.maxSupply).toBe(10)
    const keys = Array.from({length: 10}, (_, i) => i + 1)
    expect(keys.filter(key => hasBit(state.mine, key))).toEqual([2, 10])
    expect(keys.filter(key => hasBit(state.agent, key))).toEqual([])
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

  it("never goes to a key of yours past the next key", () => {
    expect(nextHeldKey(accelerant(20, bits(30)), 0)).toBe(0)
  })

  it("finds each Fibonacci level's first key", () => {
    expect([1, 2, 3, 4, 8].map(levelStart)).toEqual([1, 3, 6, 11, 87])
    expect(levelStart(20) + fibonacciLevelSupplies[19] - 1).toBe(46_365)
  })
})

const fibonacci = (minted: number): KeyMapState => ({
  minted,
  maxSupply: 46_365,
  mine: new Uint8Array(5_796),
  agent: new Uint8Array(5_796),
})

describe("key map levels", () => {
  it("steps each level through the tones in order, so neighbouring levels differ", () => {
    const tones = Array.from({length: 20}, (_, index) => levelTone(index + 1))
    expect(tones.slice(0, 6)).toEqual([0, 1, 2, 3, 0, 1])
    tones.slice(1).forEach((tone, index) => expect(tone).not.toBe(tones[index]))
  })

  it("puts each key in its level", () => {
    expect([1, 2, 3, 5, 6, 87, 141, 142, 46_365].map(fibonacciLevelOf)).toEqual([1, 1, 2, 2, 3, 8, 8, 9, 20])
  })

  // Level 7 is keys 53 to 86 and level 8 keys 87 to 141.
  it("sells the level of the next key, and moves on when that level sells out", () => {
    const grid = buildMap("fibonacci", drawnKeys("fibonacci", fibonacci(60)))
    expect(onSaleLevel(grid, fibonacci(60))).toBe(7)
    expect(onSaleLevel(grid, fibonacci(85))).toBe(7)
    expect(onSaleLevel(grid, fibonacci(86))).toBe(8)
    expect(onSaleLevel(grid, fibonacci(46_365))).toBe(0)

    expect([6, 7, 8].map(level => levelSale(7, level))).toEqual(["sold-out", "on-sale", "upcoming"])
    expect(levelSale(0, 20)).toBe("sold-out")
    expect(levelHeading(3, "sold-out")).toBe("Level 3 · sold out")
    expect(levelHeading(7, "on-sale")).toBe("Level 7 · on sale now")
    expect(levelHeading(9, "upcoming")).toBe("Level 9")
  })

  it("draws the keys sold, the rest of the level on sale and the whole level after it", () => {
    expect(drawnKeys("fibonacci", fibonacci(60))).toBe(141)
    expect(drawnKeys("fibonacci", fibonacci(86))).toBe(230)
    expect(drawnKeys("fibonacci", fibonacci(0))).toBe(5)
    expect(drawnKeys("fibonacci", fibonacci(17_768))).toBe(46_365)
    expect(drawnKeys("fibonacci", fibonacci(46_365))).toBe(46_365)
    // A fleet without levels is drawn whole.
    expect(drawnKeys("accelerant", accelerant(10, bits()))).toBe(2_000)
    expect(drawnKeys("classic", {...accelerant(0, bits()), maxSupply: 144})).toBe(144)
  })

  it("marks keys not sold yet, other than the next, and says so", () => {
    const state = fibonacci(60)
    const grid = buildMap("fibonacci", drawnKeys("fibonacci", state))
    expect([60, 61, 62, 100].map(key => keyMarks(state, key, 0, 0))).toEqual(["", "next", "unsold", "unsold"])
    expect(describeKey(grid, state, 100)).toBe("Key 100, level 8, not sold yet.")
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
