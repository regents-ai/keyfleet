import {afterEach, beforeEach, expect, it, vi} from "vitest"

import {KeyCards} from "../js/hooks/key_cards"

// R-20261019-cards-rest-off-screen: the homepage's Key cards turned over
// forever, on screen or not.

type Seen = (entries: {isIntersecting: boolean}[]) => void

let watching: {seen: Seen; watched: unknown[]; disconnected: boolean}[]

// A deck as the hook marks it.
const deck = () => {
  const marks = new Set<string>()
  return {
    marks,
    toggleAttribute: (name: string, on: boolean) => (on ? marks.add(name) : marks.delete(name)),
  }
}

const mount = (el: ReturnType<typeof deck>) => {
  const hook = {el} as unknown as {el: HTMLElement}
  KeyCards.mounted!.call(hook)
  return {hook, watch: watching.at(-1)!}
}

beforeEach(() => {
  watching = []
  vi.stubGlobal(
    "IntersectionObserver",
    class {
      entry: {seen: Seen; watched: unknown[]; disconnected: boolean}
      constructor(seen: Seen) {
        this.entry = {seen, watched: [], disconnected: false}
        watching.push(this.entry)
      }
      observe(el: unknown) {
        this.entry.watched.push(el)
      }
      disconnect() {
        this.entry.disconnected = true
      }
    },
  )
})

afterEach(() => {
  vi.unstubAllGlobals()
})

it("turns the cards only while they are on screen", () => {
  const el = deck()
  const {watch} = mount(el)

  expect(watch.watched).toEqual([el])
  expect(el.marks.has("data-cards-turning")).toBe(false)

  watch.seen([{isIntersecting: true}])
  expect(el.marks.has("data-cards-turning")).toBe(true)

  watch.seen([{isIntersecting: false}])
  expect(el.marks.has("data-cards-turning")).toBe(false)

  // Several changes in one report: where the deck stands now wins.
  watch.seen([{isIntersecting: false}, {isIntersecting: true}])
  expect(el.marks.has("data-cards-turning")).toBe(true)
})

it("stops watching when the deck leaves the page", () => {
  const {hook, watch} = mount(deck())
  KeyCards.destroyed!.call(hook)
  expect(watch.disconnected).toBe(true)
})
