/**
 * Panels that slide in: a drawer from the side, a menu under its button and a
 * dialog rising like a sheet. The page opens and closes them itself, so these
 * islands only move a panel as it opens, and only when a pointer press opened
 * it. Closing is instant, as the page already hid the panel.
 */
import {spring, type AnimationParams} from "animejs"
import {play, rest, SLOW, still, stop, takePointerPress} from "./shared"
import type {Hook} from "../../hook_composition"

// Each panel moves from where it waits while closed to where the stylesheet
// puts it. Moves in percent name both ends, so they stay a share of the
// panel's own size.
const PANELS: Record<string, Record<string, AnimationParams>> = {
  drawer: {
    spring: {x: ["100%", "0%"], ease: spring({bounce: 0.3, duration: 380})},
  },
  sheet: {
    spring: {y: ["100%", "0%"], ease: spring({bounce: 0.35, duration: 400})},
  },
  menu: {
    pop: {y: [-6, 0], scale: [0.9, 1], opacity: [0, 1], duration: SLOW, ease: "outBack(2.2)"},
  },
}

// Showing: not hidden, and not inside a closed disclosure.
const shown = (el: HTMLElement) => !el.hidden && el.closest("details:not([open])") === null

type SlidesHook = {el: HTMLElement; watch?: MutationObserver}

/**
 * An island holding panels marked `data-panel="drawer"` or `"menu"`, each
 * moving as `data-drawer` or `data-menu` on the island says. A panel opens
 * when its `hidden` goes, or when the disclosure around it opens. The page
 * puts both back after every update, so a panel that is open before and after
 * an update is left alone. A panel closed mid-move is put back at rest; what
 * moves inside it carries on and ends on its own.
 */
export const Slides: Hook = {
  mounted(this: SlidesHook) {
    const island = this.el
    const panels = () => [...island.querySelectorAll<HTMLElement>("[data-panel]")]
    const open = new Set(panels().filter(shown))

    const slide = (el: HTMLElement) => {
      const kind = el.dataset.panel as string
      play(el, PANELS[kind][island.dataset[kind] as string])
    }

    this.watch = new MutationObserver(() => {
      const opened = []
      for (const el of panels()) {
        if (shown(el) === open.has(el)) continue
        if (shown(el)) {
          open.add(el)
          opened.push(el)
        } else {
          open.delete(el)
          rest(el)
        }
      }
      if (opened.length > 0 && takePointerPress() && !still()) opened.forEach(slide)
    })
    this.watch.observe(island, {subtree: true, attributes: true, attributeFilter: ["hidden", "open"]})
  },

  destroyed(this: SlidesHook) {
    this.watch?.disconnect()
    stop(this.el)
  },
}

type SheetHook = {el: HTMLDialogElement}

/**
 * A dialog the page opens by adding it, composed after `ModalDialog` so it is
 * already open. It rises as `data-variant` says when a pointer press opened it.
 */
export const Sheet: Hook = {
  mounted(this: SheetHook) {
    const dialog = this.el
    if (takePointerPress() && !still()) play(dialog, PANELS.sheet[dialog.dataset.variant as string])
  },

  destroyed(this: SheetHook) {
    stop(this.el)
  },
}
