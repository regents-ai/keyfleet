import {describe, expect, it} from "vitest"

import {preview} from "../js/hooks/key_map/preview"

const marked = (minted: number, layout: Parameters<typeof preview>[0]) =>
  preview(layout, minted).tiles.filter(tile => tile.mark === "next").map(tile => tile.key)

describe("a fleet's still preview", () => {
  it("frames the next key on sale, marked as the map marks it", () => {
    for (const layout of ["fibonacci", "classic", "accelerant"] as const) {
      expect(new Set(marked(0, layout))).toEqual(new Set([1]))
      expect(new Set(marked(40, layout))).toEqual(new Set([41]))
    }
  })

  it("marks sold keys plainly, keys after the next one as unsold, and draws no level headings", () => {
    const {tiles} = preview("accelerant", 12)

    expect(tiles.length).toBeGreaterThan(0)
    expect(tiles.every(tile => tile.key > 0)).toBe(true)
    for (const tile of tiles) {
      if (tile.key <= 12) expect(tile.mark).toBeUndefined()
      else if (tile.key === 13) expect(tile.mark).toBe("next")
      else expect(tile.mark).toBe("unsold")
    }
  })

  it("gives a levelled fleet's keys their level's tone and sale, and other fleets none", () => {
    const levelled = preview("fibonacci", 3).tiles
    expect(levelled.find(tile => tile.key === 1)).toMatchObject({tone: 0, level: "sold-out"})
    expect(levelled.find(tile => tile.key === 4)).toMatchObject({tone: 1, level: "on-sale", mark: "next"})

    expect(preview("classic", 3).tiles.every(tile => tile.tone === undefined && tile.level === undefined)).toBe(true)
  })

  it("opens on key 1 with nothing on sale once a fleet is sold out", () => {
    const {tiles} = preview("classic", 1_024)

    expect(tiles.some(tile => tile.key === 1)).toBe(true)
    expect(tiles.every(tile => tile.mark === undefined)).toBe(true)
  })

  it("keeps one fixed frame, centred on the key it opens on", () => {
    const [x, y, width, height] = preview("classic", 0).viewBox.split(" ").map(Number)

    expect(width / height).toBeCloseTo(1.6)
    // Key 1 of Classic sits at the origin.
    expect(x + width / 2).toBeCloseTo(0)
    expect(y + height / 2).toBeCloseTo(0)
  })
})
