/**
 * Motion for something arriving: a headline that rises in word by word and a
 * list of cards that settles into place.
 */
import {
  animate,
  cleanInlineStyles,
  createScope,
  cubicBezier,
  stagger,
  type JSAnimation,
  type Scope,
  type TextSplitter,
} from "animejs"
import {SLOW, still} from "./shared"
import type {Hook} from "../../hook_composition"

const EASE_OUT = cubicBezier(0.23, 1, 0.32, 1)

// Moves in percent name both ends, so they stay a share of each word's own
// height instead of being converted to pixels from its width.
export const HEADLINES: Record<string, (split: TextSplitter) => JSAnimation> = {
  rise: split =>
    animate(split.words as HTMLElement[], {y: ["100%", "0%"], delay: stagger(50), duration: SLOW, ease: EASE_OUT}),
}

const GRIDS: Record<string, (cards: HTMLElement[]) => JSAnimation> = {
  cascade: cards =>
    animate(cards, {
      y: {from: 16},
      opacity: {from: 0},
      delay: stagger(45),
      duration: SLOW,
      ease: EASE_OUT,
      onComplete: animation => cleanInlineStyles(animation),
    }),
}

// The first cards of a list cascade in; later ones are simply there.
const CASCADE = 12

type CascadeHook = {el: HTMLElement; scope?: Scope}

/**
 * A list of cards in a live page that settles in as `data-variant` says, once,
 * the first time it scrolls into view. One already in view when the page
 * opens, or reached from the keyboard, is simply there.
 */
export const Cascade: Hook = {
  mounted(this: CascadeHook) {
    const list = this.el
    const scope = createScope({root: list})

    this.scope = scope.add(self => {
      self!.add("cascade", () => {
        const cards = [...list.children].slice(0, CASCADE) as HTMLElement[]
        GRIDS[list.dataset.variant as string](cards)
      })

      let first = true
      const done = () => {
        watch.disconnect()
        list.removeEventListener("focusin", done)
      }
      const watch = new IntersectionObserver(([entry]) => {
        const seen = entry.isIntersecting
        if (first) {
          first = false
          if (seen) done()
          return
        }
        if (!seen) return
        done()
        if (!still()) scope.methods.cascade()
      })

      watch.observe(list)
      list.addEventListener("focusin", done)
      return done
    })
  },

  destroyed(this: CascadeHook) {
    this.scope?.revert()
  },
}
