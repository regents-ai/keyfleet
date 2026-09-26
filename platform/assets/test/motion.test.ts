import {afterEach, beforeEach, expect, it, vi} from "vitest"

// The moves themselves are Anime.js's; these tests hold the rules around them:
// who gets to move, and that a press is never held up by its motion.
const moved = vi.hoisted(() => ({squish: [] as unknown[], nope: [] as unknown[], animate: [] as unknown[][]}))

vi.mock("../js/hooks/motion/press", () => ({
  squish: (el: unknown) => moved.squish.push(el),
  nope: (el: unknown) => moved.nope.push(el),
}))

vi.mock("animejs", async original => ({
  ...(await original<typeof import("animejs")>()),
  animate: (targets: unknown[]) => moved.animate.push(targets),
  createScope: () => ({
    methods: {} as Record<string, (...args: unknown[]) => unknown>,
    add(this: {methods: Record<string, unknown>}, build: (self: unknown) => void) {
      build({add: (name: string, fn: unknown) => (this.methods[name] = fn)})
      return this
    },
    revert: () => {},
  }),
}))

import {press} from "../js/motion"
import {forgetPress, notePress, takePointerPress} from "../js/hooks/motion/shared"
import {Arrivals} from "../js/hooks/motion/moments"

let lessMotion = false

beforeEach(() => {
  lessMotion = false
  vi.stubGlobal("matchMedia", () => ({matches: lessMotion}))
})

afterEach(() => {
  vi.unstubAllGlobals()
  moved.squish.length = moved.nope.length = moved.animate.length = 0
  forgetPress()
})

function control({disabled = false, own = false} = {}) {
  const el = {
    closest: () => el,
    matches: (selector: string) => own && selector === ".rg-theme-toggle",
    getAttribute: (name: string) => (name === "aria-disabled" && disabled ? "true" : null),
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

it("a control that says it can't be used yet shakes instead", () => {
  const button = control({disabled: true})
  press(click(button, 1))
  expect(moved.nope).toEqual([button])
  expect(moved.squish).toEqual([])
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

type Item = {id: string}

function list(ids: string[]) {
  const el = {dataset: {variant: "bounce"}, children: ids.map(id => ({id}))}
  const hook = {el}
  Arrivals.mounted!.call(hook)
  const change = (next: string[]) => {
    el.children = next.map(id => ({id}))
    Arrivals.updated!.call(hook)
  }
  const arrivedIds = () => moved.animate.map(targets => (targets as Item[]).map(item => item.id))
  return {change, arrivedIds}
}

it("only the items that arrive in a list move", () => {
  const {change, arrivedIds} = list(["a", "b"])
  change(["c", "a", "b"])
  expect(arrivedIds()).toEqual([["c"]])
})

it("a list whose one line is replaced by a newer one still shows it arriving", () => {
  const {change, arrivedIds} = list(["sale-6"])
  change(["sale-7"])
  expect(arrivedIds()).toEqual([["sale-7"]])
})

it("a list swapped for another one simply shows", () => {
  const {change, arrivedIds} = list(["a", "b"])
  change(["x", "y", "z"])
  expect(arrivedIds()).toEqual([])
})

it("a reader who asked for less motion sees new items without movement", () => {
  const {change, arrivedIds} = list(["a"])
  lessMotion = true
  change(["b", "a"])
  expect(arrivedIds()).toEqual([])
})
