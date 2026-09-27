import {afterEach, beforeEach, expect, it, vi} from "vitest"

// The moves themselves are Anime.js's; these tests hold the rules around them:
// who gets to move, and that a press is never held up by its motion.
const moved = vi.hoisted(() => ({squish: [] as unknown[], animate: [] as unknown[][]}))

vi.mock("../js/hooks/motion/press", () => ({
  squish: (el: unknown) => moved.squish.push(el),
}))

vi.mock("animejs", async original => {
  const anime = await original<typeof import("animejs")>()
  return {
    ...anime,
    animate: (targets: unknown[], params: {onComplete: (done: unknown) => void}) => {
      moved.animate.push(targets)
      return move(params.onComplete)
    },
    utils: {...anime.utils, cleanInlineStyles: () => {}},
  }
})

import {mountMotion, press} from "../js/motion"
import {forgetPress, notePress, play, stop, takePointerPress} from "../js/hooks/motion/shared"
import {Arrivals} from "../js/hooks/motion/moments"

let lessMotion = false

beforeEach(() => {
  lessMotion = false
  vi.stubGlobal("matchMedia", () => ({matches: lessMotion}))
})

afterEach(() => {
  vi.unstubAllGlobals()
  moved.squish.length = moved.animate.length = 0
  forgetPress()
})

// A move that ends when `end` is called, or is put back by `revert`.
function move(onComplete: (done: unknown) => void) {
  const animation = {end: () => onComplete(animation), revert: vi.fn()}
  return animation
}

type Move = ReturnType<typeof move>

// A control that matches a selector list when one of its parts names the
// control's marker: its class or its attribute.
function control({own = false, wallet}: {own?: boolean; wallet?: string} = {}) {
  const label = {label: true}
  const marker = own ? ".rg-theme-toggle" : wallet && `[${wallet}]`
  const el = {
    label,
    closest: () => el,
    matches: (selector: string) => marker !== undefined && selector.split(",").some(part => part.trim() === marker),
    querySelector: (selector: string) => (selector === "[data-press-label]" && wallet ? label : null),
  }
  return el
}

// A click from a pointer reports how many presses made it; Enter and Space report none.
function click(target: unknown, detail: number) {
  return {target, detail, preventDefault: vi.fn(), stopPropagation: vi.fn()} as unknown as MouseEvent & {
    preventDefault: ReturnType<typeof vi.fn>
    stopPropagation: ReturnType<typeof vi.fn>
  }
}

it("a pointer press squishes the control it pressed", () => {
  const button = control()
  press(click(button, 1))
  expect(moved.squish).toEqual([button])
})

it("a keyboard press answers at once, without a squish", () => {
  press(click(control(), 0))
  expect(moved.squish).toEqual([])
})

it("a reader who asked for less motion gets no squish", () => {
  lessMotion = true
  press(click(control(), 1))
  expect(moved.squish).toEqual([])
})

it("a wallet button squishes only its label, so the button itself never shrinks", () => {
  for (const wallet of ["data-onchain-step", "data-demo-send"]) {
    const button = control({wallet})
    press(click(button, 1))
    expect(moved.squish).toEqual([button.label])
    moved.squish.length = 0
  }
})

it("the theme switch keeps its own motion", () => {
  press(click(control({own: true}), 1))
  expect(moved.squish).toEqual([])
})

it("the press goes through untouched and nothing waits on the motion", () => {
  const event = click(control(), 2)
  expect(press(event)).toBeUndefined()
  expect(event.preventDefault).not.toHaveBeenCalled()
  expect(event.stopPropagation).not.toHaveBeenCalled()
})

it("what a press opens asks once whether a pointer made it", () => {
  notePress(click(control(), 1))
  expect(takePointerPress()).toBe(true)
  expect(takePointerPress()).toBe(false)
})

it("a key pressed after a pointer press means the next opening came from the keyboard", () => {
  notePress(click(control(), 1))
  forgetPress()
  expect(takePointerPress()).toBe(false)
})

it("going back or forward forgets the last press, so what reopens appears at once", () => {
  const listeners = new Map<string, () => void>()
  const listen = (type: string, listener: () => void) => listeners.set(type, listener)
  vi.stubGlobal("document", {addEventListener: () => {}, querySelector: () => null})
  vi.stubGlobal("window", {addEventListener: listen})
  mountMotion()

  notePress(click(control(), 1))
  listeners.get("popstate")!()
  expect(takePointerPress()).toBe(false)
})

// An element in an island, as `stop` walks it.
const island = (...inside: Element[]) => ({querySelectorAll: () => inside}) as unknown as Element

it("a move begun on something still moving first puts the earlier move back at rest", () => {
  const el = {} as Element
  const earlier = play(el, {}) as unknown as Move
  play(el, {})
  expect(earlier.revert).toHaveBeenCalledOnce()
})

it("a move that has ended is never put back, so it can't undo what came after it", () => {
  const el = {} as Element
  const ended = play(el, {}) as unknown as Move
  ended.end()
  play(el, {})
  stop(island())
  expect(ended.revert).not.toHaveBeenCalled()
})

it("whatever still moves inside an island is put back at rest when the island goes", () => {
  const inside = {} as Element
  const outside = {} as Element
  const moving = play(inside, {}) as unknown as Move
  const elsewhere = play(outside, {}) as unknown as Move
  stop(island(inside))
  expect(moving.revert).toHaveBeenCalledOnce()
  expect(elsewhere.revert).not.toHaveBeenCalled()
})

type Item = {id: string}

// A list naming what it shows, as the server renders it.
function list(ids: string[], shows = "fleet-1:1") {
  const el = {dataset: {variant: "bounce", list: shows}, children: ids.map(id => ({id}))}
  const hook = {el}
  Arrivals.mounted!.call(hook)
  const change = (next: string[], nowShows = el.dataset.list) => {
    el.dataset.list = nowShows
    el.children = next.map(id => ({id}))
    Arrivals.updated!.call(hook)
  }
  return change
}

// The ids of the items each arrival moved, across every list.
const arrivedIds = () => moved.animate.map(targets => (targets as Item[]).map(item => item.id))

it("only the items that arrive in a list move", () => {
  const change = list(["a", "b"])
  change(["c", "a", "b"])
  expect(arrivedIds()).toEqual([["c"]])
})

it("a list whose one line is replaced by a newer one still shows it arriving", () => {
  const change = list(["sale-6"])
  change(["sale-7"])
  expect(arrivedIds()).toEqual([["sale-7"]])
})

it("a list that now shows another room simply shows its messages, however many there are", () => {
  list([], "fleet-1/general")(["m-1", "m-2", "m-3"], "fleet-1/plans")
  list(["m-4"], "fleet-1/general")(["m-9"], "fleet-1/plans")
  expect(arrivedIds()).toEqual([])
})

it("older lines shown on request simply show", () => {
  const change = list(["a", "b"], "fleet-1:1")
  change(["a", "b", "c", "d"], "fleet-1:2")
  expect(arrivedIds()).toEqual([])
})

it("a list that has just changed what it shows still bounces what arrives next", () => {
  const change = list(["a"], "fleet-1/general")
  change(["x"], "fleet-1/plans")
  change(["y", "x"])
  expect(arrivedIds()).toEqual([["y"]])
})

it("a reader who asked for less motion sees new items without movement", () => {
  const change = list(["a"])
  lessMotion = true
  change(["b", "a"])
  expect(arrivedIds()).toEqual([])
})
