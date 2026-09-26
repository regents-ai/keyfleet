/**
 * Motion for things the server decides: a list that changes, a number that
 * moves and a refusal. The page renders every result first; these islands
 * only animate from the old picture to the new one.
 */
import {
  animate,
  createScope,
  spring,
  splitText,
  stagger,
  utils,
  type JSAnimation,
  type Scope,
  type TextSplitter,
} from "animejs"
import {SLOW, still} from "./shared"
import {deny} from "./press"
import type {Hook} from "../../hook_composition"

// How the items the server adds to a list arrive.
const ARRIVALS: Record<string, (items: HTMLElement[]) => JSAnimation> = {
  bounce: items =>
    animate(items, {
      y: [-12, 0],
      opacity: [0, 1],
      ease: spring({bounce: 0.35, duration: 420}),
      onComplete: animation => utils.cleanInlineStyles(animation),
    }),
}

type ArrivalsHook = {el: HTMLElement; scope?: Scope; ids?: Set<string>}

const itemsOf = (list: HTMLElement) => [...list.children] as HTMLElement[]
const idsOf = (items: HTMLElement[]) => new Set(items.map(item => item.id))

/**
 * A list the server owns, each item with its own id. Only the items that
 * arrive move; the rest stay put. When several items arrive and none of the
 * old ones is left, the list has been swapped for another one and simply
 * shows; a single line replacing a single line still arrives.
 *
 * The page may empty the list before saying it is about to change, so the
 * items to compare against are the ones seen after the last change.
 */
export const Arrivals: Hook = {
  mounted(this: ArrivalsHook) {
    const list = this.el
    this.ids = idsOf(itemsOf(list))
    this.scope = createScope({root: list}).add(self => {
      self!.add("arrive", (items: HTMLElement[]) => ARRIVALS[list.dataset.variant as string](items))
    })
  },

  updated(this: ArrivalsHook) {
    const before = this.ids!
    const items = itemsOf(this.el)
    this.ids = idsOf(items)
    const arrived = items.filter(item => !before.has(item.id))
    const swapped = arrived.length > 1 && arrived.length === items.length && before.size > 0
    if (arrived.length > 0 && !swapped && !still()) this.scope!.methods.arrive(arrived)
  },

  destroyed(this: ArrivalsHook) {
    this.scope?.revert()
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

type CounterHook = {el: HTMLElement; scope?: Scope; split?: TextSplitter; before?: string}

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
    const scope = createScope({root: this.el})

    this.scope = scope.add(self => {
      self!.add("roll", (split: TextSplitter, digits: HTMLElement[], up: boolean) => {
        animate(digits, {
          ...ROLLS[this.el.dataset.variant as string](up),
          delay: stagger(45, {from: "last"}),
          onComplete: () => join(this, split),
        })
      })
    })
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
    this.scope!.methods.roll(split, digits, worth(after) > worth(before))
  },

  destroyed(this: CounterHook) {
    join(this, this.split)
    this.scope?.revert()
  },
}

type RefusalHook = {el: HTMLElement; scope?: Scope; said?: string}

/**
 * A message the page shows when it refuses something. It shakes once when it
 * appears and again whenever it says something new, while `data-refused` is
 * on it.
 */
export const Refusal: Hook = {
  mounted(this: RefusalHook) {
    this.scope = createScope({root: this.el}).add(self => {
      self!.add("shake", () => {
        if (this.el.dataset.refused !== undefined) deny(this.el)
      })
    })
    this.said = this.el.textContent ?? ""
    this.scope.methods.shake()
  },

  updated(this: RefusalHook) {
    const said = this.el.textContent ?? ""
    if (said !== this.said) this.scope!.methods.shake()
    this.said = said
  },

  destroyed(this: RefusalHook) {
    this.scope?.revert()
  },
}
