import {describe, expect, it} from "vitest"

import {buildMap, type KeyMapGrid} from "../js/hooks/key_map/layouts"
import {keyNear} from "../js/hooks/key_map/state"

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
