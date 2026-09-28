import {afterEach, beforeEach, expect, it, vi} from "vitest"

// The moves themselves are Anime.js's; these tests hold the rules around them:
// who gets to move, and that a press is never held up by its motion.
const moved = vi.hoisted(() => ({squish: [] as unknown[], nope: [] as unknown[]}))

vi.mock("../js/hooks/motion/press", () => ({
  squish: (el: unknown) => moved.squish.push(el),
  nope: (el: unknown) => moved.nope.push(el),
}))

vi.mock("animejs", async original => {
  const anime = await original<typeof import("animejs")>()
  return {
    ...anime,
    animate: (_targets: unknown[], params: {onComplete: (done: unknown) => void}) => move(params.onComplete),
    utils: {...anime.utils, cleanInlineStyles: () => {}},
  }
})

// A control as a press finds it. It answers `closest` for the kit's selector
// of pressable controls, which leaves out the theme switch, and for a switch
// on the page asking for less motion.
class Control {
  label = {label: true}
  constructor(private marks: {own?: boolean; wallet?: boolean; disabled?: boolean; reduced?: boolean} = {}) {}

  closest(selector: string) {
    if (selector === "[data-motion='reduced']") return this.marks.reduced ? this : null
    return this.marks.own && selector.includes(":not(.rg-theme-toggle") ? null : this
  }

  getAttribute(name: string) {
    return name === "aria-disabled" && this.marks.disabled ? "true" : null
  }

  querySelector(selector: string) {
    return selector === "[data-press-label]" && this.marks.wallet ? this.label : null
  }
}
vi.stubGlobal("Element", Control)

import {press} from "../js/motion"
import {lastInputByPointer, play, watchInput} from "../js/hooks/motion/shared"

let lessMotion = false

// How the reader last gave input, as the page-wide listeners note it.
const input = new Map<string, () => void>()
const listen = (type: string, listener: () => void) => input.set(type, listener)
watchInput({addEventListener: listen, defaultView: {addEventListener: listen}} as unknown as Document)

beforeEach(() => {
  lessMotion = false
  vi.stubGlobal("matchMedia", () => ({matches: lessMotion}))
})

afterEach(() => {
  moved.squish.length = moved.nope.length = 0
})

// A move that ends when `end` is called, or is put back by `revert`.
function move(onComplete: (done: unknown) => void) {
  const animation = {end: () => onComplete(animation), revert: vi.fn()}
  return animation
}

type Move = ReturnType<typeof move>

// A click from a pointer reports how many presses made it; Enter and Space report none.
function click(target: unknown, detail: number) {
  return {target, detail, preventDefault: vi.fn(), stopPropagation: vi.fn()} as unknown as MouseEvent & {
    preventDefault: ReturnType<typeof vi.fn>
    stopPropagation: ReturnType<typeof vi.fn>
  }
}

it("a pointer press squishes the control it pressed", () => {
  const button = new Control()
  press(click(button, 1))
  expect(moved.squish).toEqual([button])
})

it("a keyboard press answers at once, without a squish", () => {
  press(click(new Control(), 0))
  expect(moved.squish).toEqual([])
})

it("a reader who asked for less motion gets no squish, in their settings or on the page", () => {
  lessMotion = true
  press(click(new Control(), 1))
  lessMotion = false
  press(click(new Control({reduced: true}), 1))
  expect(moved.squish).toEqual([])
})

it("a wallet button squishes only its label, so the button itself never shrinks", () => {
  const button = new Control({wallet: true})
  press(click(button, 1))
  expect(moved.squish).toEqual([button.label])
})

it("a button that says it can't be used yet shakes its head instead of squishing", () => {
  const button = new Control({disabled: true})
  press(click(button, 1))
  expect(moved.nope).toEqual([button])
  expect(moved.squish).toEqual([])
})

it("the theme switch keeps its own motion", () => {
  press(click(new Control({own: true}), 1))
  expect(moved.squish).toEqual([])
})

it("the press goes through untouched and nothing waits on the motion", () => {
  const event = click(new Control(), 2)
  expect(press(event)).toBeUndefined()
  expect(event.preventDefault).not.toHaveBeenCalled()
  expect(event.stopPropagation).not.toHaveBeenCalled()
})

it("what opens moves only while the reader was last using a pointer", () => {
  input.get("pointerdown")!()
  expect(lastInputByPointer()).toBe(true)
  input.get("keydown")!()
  expect(lastInputByPointer()).toBe(false)
  input.get("pointermove")!()
  expect(lastInputByPointer()).toBe(true)
})

it("going back or forward starts afresh, so what reopens appears at once", () => {
  input.get("pointerdown")!()
  input.get("popstate")!()
  expect(lastInputByPointer()).toBe(false)
})

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
  expect(ended.revert).not.toHaveBeenCalled()
})
