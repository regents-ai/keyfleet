import {afterEach, beforeEach, describe, expect, it, vi} from "vitest"

import {onOpenSea} from "../js/hooks/harbour_sea"

/** A page element as the rule reads it: its computed background, its own words, and whether it is a control. */
type Part = {
  readonly background?: string
  readonly image?: string
  readonly words?: string
  readonly control?: boolean
  readonly parentElement: Part | null
  readonly childNodes: {nodeType: number; textContent: string}[]
  closest(selector: string): Part | null
}

const part = (parent: Part | null, look: {background?: string; image?: string; words?: string; control?: boolean} = {}): Part => {
  const made: Part = {
    ...look,
    parentElement: parent,
    childNodes: look.words === undefined ? [] : [{nodeType: 3, textContent: look.words}],
    closest() {
      for (let at: Part | null = made; at; at = at.parentElement) if (at.control) return at
      return null
    },
  }
  return made
}

// The page's ground, then the see-through parts the shell lays over the sea.
const html = part(null, {background: "rgb(11, 11, 11)"})
const body = part(html)
const shell = part(body)
const content = part(shell)

const isOpenSea = (element: Part) => onOpenSea(element as unknown as Element)

// Sean, 19 Oct: the buildings of the sea behind the pages open their pages
// under the mouse, and the page's own parts keep every press meant for them.
describe("where the sea behind the page takes a press for a building", () => {
  beforeEach(() => {
    vi.stubGlobal("Node", {TEXT_NODE: 3})
    vi.stubGlobal("document", {documentElement: html})
    vi.stubGlobal("getComputedStyle", (element: Part) => ({
      backgroundColor: element.background ?? "rgba(0, 0, 0, 0)",
      backgroundImage: element.image ?? "none",
    }))
  })

  afterEach(() => vi.unstubAllGlobals())

  it("takes it in the page's empty margins", () => {
    expect(isOpenSea(content)).toBe(true)
    expect(isOpenSea(part(content, {background: "transparent"}))).toBe(true)
    expect(isOpenSea(part(content, {background: "color(srgb 0.1 0.2 0.3 / 0)"}))).toBe(true)
  })

  it("leaves it to anything painted, even where the sea is only dimmed", () => {
    const card = part(content, {background: "rgb(20, 20, 20)"})
    expect(isOpenSea(card)).toBe(false)
    expect(isOpenSea(part(card))).toBe(false)
    expect(isOpenSea(part(content, {background: "rgb(10, 20, 0)"}))).toBe(false)
    expect(isOpenSea(part(content, {background: "rgba(255, 255, 255, 0.5)"}))).toBe(false)
    expect(isOpenSea(part(content, {background: "color(srgb 0.1 0.2 0.3 / 0.4)"}))).toBe(false)
    expect(isOpenSea(part(content, {image: "linear-gradient(red, blue)"}))).toBe(false)
  })

  it("leaves it to words and controls standing on the sea", () => {
    expect(isOpenSea(part(content, {words: "Proposals"}))).toBe(false)
    expect(isOpenSea(part(content, {words: "  \n "}))).toBe(true)
    expect(isOpenSea(part(part(content, {control: true})))).toBe(false)
  })
})
