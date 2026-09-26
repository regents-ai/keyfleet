/**
 * Motion for things the server decides: a list that changes, a number that
 * moves and a refusal. The page renders every result first; these islands
 * only animate from the old picture to the new one.
 */
import {animate, cleanInlineStyles, spring, splitText, stagger, type JSAnimation, type TextSplitter} from "animejs"
import {play, SLOW, still, stop, type Moves} from "./shared"
import {deny} from "./press"
import type {Hook} from "../../hook_composition"

// How the items the server adds to a list arrive.
const ARRIVALS: Record<string, (items: HTMLElement[]) => JSAnimation> = {
  bounce: items =>
    animate(items, {
      y: [-12, 0],
      opacity: [0, 1],
      ease: spring({bounce: 0.35, duration: 420}),
      onComplete: animation => cleanInlineStyles(animation),
    }),
}

type ArrivalsHook = {el: HTMLElement; moves: Moves; list?: string; ids?: Set<string>}

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
    this.moves = new Set()
    this.list = this.el.dataset.list
    this.ids = idsOf(itemsOf(this.el))
  },

  updated(this: ArrivalsHook) {
    const {list, ids: before} = this
    const items = itemsOf(this.el)
    this.list = this.el.dataset.list
    this.ids = idsOf(items)
    if (this.list !== list || still()) return

    const arrived = items.filter(item => !before!.has(item.id))
    if (arrived.length > 0) play(this.moves, ARRIVALS[this.el.dataset.variant as string](arrived))
  },

  destroyed(this: ArrivalsHook) {
    stop(this.moves)
  },
}

// How the digits that changed arrive, each masked in its own slot. Moves in
// percent name both ends, so they stay a share of the digit's own height.
const ROLLS: Record<string, (up: boolean) => Record<string, unknown>> = {
  roll: up => ({y: [up ? "100%" : "-100%", "0%"], duration: SLOW, ease: "outBack(1.4)"}),
}

// The characters a split makes, which leave out spaces.
const glyphs = (el: HTMLElement) => (el.textContent ?? "").replace(/\s/g, "")
const worth = (text: string) => Number(text.replace(/[^\d.]/g, ""))

type CounterHook = {el: HTMLElement; moves: Moves; split?: TextSplitter; before?: string}

// Put the plain number back, but only for the split still on the page: an
// older one would write its stale number over the new one.
function join(hook: CounterHook, split?: TextSplitter) {
  if (split === undefined || split !== hook.split) return
  split.revert()
  hook.split = undefined
}

/**
 * A number the server changes. Only the characters that changed move, the
 * ones nearest the end first, like a counter turning over. The number is
 * split into pieces for the move and joined back as soon as it ends, so the
 * page always patches the plain text it rendered.
 */
export const Counter: Hook = {
  mounted(this: CounterHook) {
    this.moves = new Set()
  },

  beforeUpdate(this: CounterHook) {
    join(this, this.split)
    this.before = glyphs(this.el)
  },

  updated(this: CounterHook) {
    const before = this.before as string
    const after = glyphs(this.el)
    if (before === after || still()) return

    const split = splitText(this.el, {words: false, chars: {wrap: "clip"}})
    const digits = (split.chars as HTMLElement[]).filter((_char, i) => before.at(i - after.length) !== after[i])
    this.split = split
    const roll = animate(digits, {
      ...ROLLS[this.el.dataset.variant as string](worth(after) > worth(before)),
      delay: stagger(45, {from: "last"}),
      onComplete: () => join(this, split),
    })
    play(this.moves, roll)
  },

  destroyed(this: CounterHook) {
    stop(this.moves)
    join(this, this.split)
  },
}

type RefusalHook = {el: HTMLElement; moves: Moves; said?: string}

// Shake while `data-refused` is on the message.
function shake(hook: RefusalHook) {
  if (hook.el.dataset.refused === undefined) return
  const move = deny(hook.el)
  if (move !== undefined) play(hook.moves, move)
}

/**
 * A message the page shows when it refuses something. It shakes once when it
 * appears and again whenever it says something new, while `data-refused` is
 * on it.
 */
export const Refusal: Hook = {
  mounted(this: RefusalHook) {
    this.moves = new Set()
    this.said = this.el.textContent ?? ""
    shake(this)
  },

  updated(this: RefusalHook) {
    const said = this.el.textContent ?? ""
    if (said !== this.said) shake(this)
    this.said = said
  },

  destroyed(this: RefusalHook) {
    stop(this.moves)
  },
}
