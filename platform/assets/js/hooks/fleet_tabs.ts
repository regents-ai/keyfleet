import type {Scope} from "animejs"
import {composeHooks, type Hook} from "../hook_composition"
import {CurrentTab} from "./current_tab"
import {MotionTabs} from "./motion/reveals"

type FleetTabsHook = {el: HTMLElement; scope?: Scope}

/**
 * Once the kit's tabs have put the mark under the open tab, the tab's own
 * underline gives way to it. The page's fonts change each tab's width, so the
 * mark is placed again once they have arrived.
 */
const markPlaced: Hook = {
  mounted(this: FleetTabsHook) {
    this.el.dataset.inkReady = ""
    void document.fonts.ready.then(() => {
      if (this.el.isConnected) this.scope?.methods.place()
    })
  },
}

/**
 * A fleet's tabs: the open one stays in view on a phone, and the mark under
 * it glides to the next tab picked with a mouse or finger.
 */
export const FleetTabs = composeHooks(CurrentTab, MotionTabs, markPlaced)
