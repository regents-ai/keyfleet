import {describe, expect, it} from "vitest"

import {EDGE, cardSpot, holeAround, pieces, underFoot, type Box, type Size} from "../js/tour/place"

const WIDE: Size = {w: 1280, h: 800}
const PHONE: Size = {w: 390, h: 844}
const CARD: Size = {w: 280, h: 170}
const DOCKED: Size = {w: 358, h: 150}
// Buy Key on the fleet's page and in the header, where a wide screen has them.
const BUY: Box[] = [
  {x: 376, y: 204, w: 116, h: 40},
  {x: 1016, y: 11, w: 116, h: 42},
]

const overlaps = (a: Box, b: Box) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
const onScreen = (box: Box, view: Size) => box.x >= 0 && box.y >= 0 && box.x + box.w <= view.w && box.y + box.h <= view.h
const ringOf = (hole: Box): Box => ({x: hole.x - EDGE, y: hole.y - EDGE, w: hole.w + 2 * EDGE, h: hole.h + 2 * EDGE})

// Parts of a few sizes, from a tab to a strip of Key cards, all over the screen.
function* parts(view: Size) {
  for (const [w, h] of [
    [60, 40],
    [180, 44],
    [400, 120],
  ]) {
    for (let x = 0; x + w <= view.w; x += 37) {
      for (let y = 0; y + h <= view.h; y += 29) yield {x, y, w, h}
    }
  }
}

describe("the dimming", () => {
  it("covers the whole screen but the hole, with the ring just outside the hole", () => {
    for (const part of parts(WIDE)) {
      const hole = holeAround(part)
      const {shade, ring} = pieces(hole, WIDE)
      const left = Math.round(Math.max(hole.x, 0))
      const top = Math.round(Math.max(hole.y, 0))
      const right = Math.round(Math.min(hole.x + hole.w, WIDE.w))
      const bottom = Math.round(Math.min(hole.y + hole.h, WIDE.h))
      const open = {x: left, y: top, w: right - left, h: bottom - top}

      const area = shade.reduce((sum, box) => sum + box.w * box.h, 0)
      expect(area + open.w * open.h).toBe(WIDE.w * WIDE.h)
      for (const [i, a] of shade.entries()) {
        expect(overlaps(a, open)).toBe(false)
        for (const b of shade.slice(i + 1)) expect(overlaps(a, b)).toBe(false)
      }
      for (const line of ring) expect(overlaps(line, open)).toBe(false)
      expect(Math.min(...ring.map(line => line.x))).toBe(left - EDGE)
      expect(Math.max(...ring.map(line => line.y + line.h))).toBe(bottom + EDGE)
    }
  })
})

describe("the card on a wide screen", () => {
  it("lies on the screen, off the ring and off Buy Key, wherever the part is", () => {
    for (const part of parts(WIDE)) {
      const hole = holeAround(part)
      const card = {...cardSpot(hole, CARD, WIDE, false, BUY), ...CARD}
      expect(onScreen(card, WIDE)).toBe(true)
      expect(overlaps(card, ringOf(hole))).toBe(false)
      for (const buy of BUY) expect(overlaps(card, buy)).toBe(false)
    }
  })

  it("keeps on the screen and off Buy Key when it can only lie over the part", () => {
    // A part filling nearly the whole screen, with Buy Key in the first corner tried.
    const hole = holeAround({x: 100, y: 100, w: 1080, h: 600})
    const buy = {x: 1100, y: 700, w: 116, h: 40}
    const card = {...cardSpot(hole, CARD, WIDE, false, [buy]), ...CARD}
    expect(onScreen(card, WIDE)).toBe(true)
    expect(overlaps(card, buy)).toBe(false)
  })

  it("stands in the middle of the screen for a step with no part, or at the middle of its foot", () => {
    const middle = cardSpot(undefined, CARD, WIDE, false, BUY)
    expect(middle).toEqual({x: (WIDE.w - CARD.w) / 2, y: (WIDE.h - CARD.h) / 2})

    const markPresent = {x: 645, y: 434, w: 153, h: 42}
    const foot = cardSpot(undefined, CARD, WIDE, false, [...BUY, markPresent])
    expect(foot.x).toBe((WIDE.w - CARD.w) / 2)
    expect(overlaps({...foot, ...CARD}, markPresent)).toBe(false)
    expect(onScreen({...foot, ...CARD}, WIDE)).toBe(true)
  })
})

describe("the card on a phone", () => {
  it("docks along the foot, off the ring, for a part above it, and along the top otherwise", () => {
    for (const part of parts(PHONE)) {
      const hole = holeAround(part)
      const card = {...cardSpot(hole, DOCKED, PHONE, true), ...DOCKED}
      expect(onScreen(card, PHONE)).toBe(true)
      if (!underFoot(hole, DOCKED, PHONE)) expect(card.y).toBe(PHONE.h - DOCKED.h - 16)
      if (part.h < PHONE.h - 2 * DOCKED.h - 64) expect(overlaps(card, ringOf(hole))).toBe(false)
    }
  })
})
