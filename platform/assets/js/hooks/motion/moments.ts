/**
 * Motion for things the server decides: a list that changes, such as a stack
 * of notes, and a figure that moves. The page renders every result first;
 * these islands only animate from the old picture to the new one.
 */
import {
  animate,
  createLayout,
  createScope,
  spring,
  splitText,
  stagger,
  type AnimationParams,
  type JSAnimation,
  type LayoutAnimationParams,
  type Scope,
  type TextSplitter,
} from "animejs"
import {BASE, CLIPPED_CHAR, SLOW, play, still} from "./shared"
import {deny} from "./press"
import type {Hook} from "../../hook_composition"

// How a list moves when the server adds, reorders or drops its items: `bounce`
// for lists and `pop` for notes that come and go. Each is built fresh per
// change because a stagger remembers the items it measured.
export const LAYOUTS: Record<string, () => LayoutAnimationParams> = {
  bounce: () => ({
    ease: spring({bounce: 0.35, duration: 420}),
    enterFrom: {opacity: 0, transform: "translateY(-12px)"},
    leaveTo: {opacity: 0, transform: "scale(.9)", ease: "in(3)", duration: BASE},
  }),
  pop: () => ({
    ease: spring({bounce: 0.45, duration: 360}),
    enterFrom: {opacity: 0, transform: "scale(.6)"},
    leaveTo: {opacity: 0, transform: "scale(.8)", ease: "in(3)", duration: BASE},
  }),
}

type ListHook = {el: HTMLElement; scope?: Scope}

/**
 * A list the server owns, built from a table of versions. It renders
 * `data-layout-id` on the list and on every item, names the items in
 * `data-children` and the version in `data-variant`. An item that is leaving
 * is hidden for a moment before the server drops it, so it can fade out while
 * its neighbours close the gap.
 */
export const listHook = (layouts: Record<string, () => LayoutAnimationParams>): Hook => ({
  mounted(this: ListHook) {
    const scope = createScope({root: this.el})

    this.scope = scope.add(() => {
      const layout = createLayout(this.el, {children: this.el.dataset.children})
      scope.add("record", () => layout.record())
      scope.add("move", () => layout.animate(layouts[this.el.dataset.variant ?? ""]()))
    })
  },

  beforeUpdate(this: ListHook) {
    this.scope?.methods.record()
  },

  updated(this: ListHook) {
    if (!still(this.el)) this.scope?.methods.move()
  },

  destroyed(this: ListHook) {
    this.scope?.revert()
  },
})

export const MotionList = listHook(LAYOUTS)

// How the digits that changed arrive. `clip` masks each digit in its own
// slot, so a digit rolling in is hidden until it reaches the slot.
export type Roll = {clip: boolean; move: (up: boolean) => AnimationParams}

export const ROLLS: Record<string, Roll> = {
  roll: {clip: true, move: up => ({y: [up ? "100%" : "-100%", "0%"], duration: SLOW, ease: "outBack(1.4)"})},
}

const worth = (text: string) => Number(text.replace(/\D/g, ""))

// The figures inside a part of the page, each marked `data-count`.
const figures = (root: HTMLElement) => [...root.querySelectorAll<HTMLElement>("[data-count]")]

type CountHook = {el: HTMLElement; scope?: Scope; before?: string[]; splits: Set<TextSplitter>}

// Put the plain figure back, but only for a split that is still on the page:
// an older one would write its stale figure over the new one.
function join(hook: CountHook, split: TextSplitter) {
  if (!hook.splits.delete(split)) return
  split.revert()
}

/**
 * Figures the server changes, built from a table of versions. Only the digits
 * that changed move, the ones nearest the end first, like a counter turning
 * over. The digits are split into pieces for the move and joined back as soon
 * as it ends, so the page always patches the plain figure it rendered.
 */
export const countHook = (rolls: Record<string, Roll>): Hook => ({
  mounted(this: CountHook) {
    const scope = createScope({root: this.el})
    this.splits = new Set()

    this.scope = scope.add(() => {
      scope.add("roll", (split: TextSplitter, digits: HTMLElement[], up: boolean) => {
        animate(digits, {
          ...rolls[this.el.dataset.variant ?? ""].move(up),
          delay: stagger(45, {from: "last"}),
          onComplete: () => join(this, split),
        })
      })
    })
  },

  beforeUpdate(this: CountHook) {
    for (const split of this.splits) join(this, split)
    this.before = figures(this.el).map(figure => figure.textContent ?? "")
  },

  updated(this: CountHook) {
    const before = this.before ?? []
    const after = figures(this.el)
    if (still(this.el) || after.length !== before.length) return

    const {clip} = rolls[this.el.dataset.variant ?? ""]
    after.forEach((figure, index) => {
      const was = before[index]
      const now = figure.textContent ?? ""
      if (was === now) return

      const split = splitText(figure, {words: false, chars: clip ? CLIPPED_CHAR : true})
      const digits = split.chars.filter((_char, i) => was.at(i - now.length) !== now[i])
      this.splits.add(split)
      this.scope?.methods.roll(split, digits, worth(now) > worth(was))
    })
  },

  destroyed(this: CountHook) {
    for (const split of this.splits) join(this, split)
    this.scope?.revert()
  },
})

export const MotionCount = countHook(ROLLS)

// Keyfleet's own islands follow. Each does something the ones above don't yet.

// How the items the server adds to a list arrive.
const ARRIVALS: Record<string, (items: HTMLElement[]) => JSAnimation> = {
  bounce: items => play(items, {y: [-12, 0], opacity: [0, 1], ease: spring({bounce: 0.35, duration: 420})}),
}

type ArrivalsHook = {el: HTMLElement; list?: string; ids?: Set<string>}

const itemsOf = (list: HTMLElement) => [...list.children] as HTMLElement[]
const idsOf = (items: HTMLElement[]) => new Set(items.map(item => item.id))

/**
 * A list the server owns, each item with its own id, and `data-list` naming
 * what the list shows: which room, which key's messages, which fleet and how
 * many pages of it. Only the items that arrive in the same list move; the
 * rest stay put. When `data-list` names something else, the list simply shows.
 *
 * The page may empty the list before saying it is about to change, so the
 * items to compare against are the ones seen after the last change.
 */
export const Arrivals: Hook = {
  mounted(this: ArrivalsHook) {
    this.list = this.el.dataset.list
    this.ids = idsOf(itemsOf(this.el))
  },

  updated(this: ArrivalsHook) {
    const {list, ids: before} = this
    const items = itemsOf(this.el)
    this.list = this.el.dataset.list
    this.ids = idsOf(items)
    if (this.list !== list || still(this.el)) return

    const arrived = items.filter(item => !before!.has(item.id))
    if (arrived.length > 0) ARRIVALS[this.el.dataset.variant as string](arrived)
  },
}

// The characters a split makes, which leave out spaces, and what a figure is
// worth, decimals included, so a price from 1.75 to 2 rolls up.
const glyphs = (el: HTMLElement) => (el.textContent ?? "").replace(/\s/g, "")
const decimalWorth = (text: string) => Number(text.replace(/[^\d.]/g, ""))

type CounterHook = {el: HTMLElement; split?: TextSplitter; before?: string}

// Put the plain number back, but only for the split still on the page: an
// older one would write its stale number over the new one.
function joinCounter(hook: CounterHook, split?: TextSplitter) {
  if (split === undefined || split !== hook.split) return
  split.revert()
  hook.split = undefined
}

/**
 * A number the server changes, the element itself, rolling as `data-variant`
 * names in `ROLLS`. Only the characters that changed move, the ones nearest
 * the end first, like a counter turning over. Unlike `countHook`, a figure
 * may carry words and spaces, such as "12.5 USDC". The number is split into
 * pieces for the move and joined back as soon as it ends, so the page always
 * patches the plain text it rendered.
 */
export const Counter: Hook = {
  beforeUpdate(this: CounterHook) {
    joinCounter(this, this.split)
    this.before = glyphs(this.el)
  },

  updated(this: CounterHook) {
    const before = this.before as string
    const after = glyphs(this.el)
    if (before === after || still(this.el)) return

    const {clip, move} = ROLLS[this.el.dataset.variant as string]
    const split = splitText(this.el, {words: false, chars: clip ? CLIPPED_CHAR : true})
    const digits = split.chars.filter((_char, i) => before.at(i - after.length) !== after[i])
    this.split = split
    play(digits, {...move(decimalWorth(after) > decimalWorth(before)), delay: stagger(45, {from: "last"})}).then(() =>
      joinCounter(this, split),
    )
  },

  destroyed(this: CounterHook) {
    joinCounter(this, this.split)
  },
}

type RefusalHook = {el: HTMLElement; said?: string}

// Shake while `data-refused` is on the message.
function shake(hook: RefusalHook) {
  if (hook.el.dataset.refused !== undefined) deny(hook.el)
}

/**
 * A message a live page shows when it refuses something. It shakes once when
 * it appears and again whenever it says something new, while `data-refused`
 * is on it.
 */
export const Refusal: Hook = {
  mounted(this: RefusalHook) {
    this.said = this.el.textContent ?? ""
    shake(this)
  },

  updated(this: RefusalHook) {
    const said = this.el.textContent ?? ""
    if (said !== this.said) shake(this)
    this.said = said
  },
}
