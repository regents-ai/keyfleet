import type {Hook} from "../hook_composition"
import {installShellPanels} from "../shell_panels"

interface SidePanelHook {
  el: HTMLElement
  panels?: ReturnType<typeof installShellPanels>
}

// The side panel on the homepage, which draws the header and panel outside the
// app shell.
export const SidePanel: Hook = {
  mounted(this: SidePanelHook) {
    this.panels = installShellPanels(this.el)
  },

  updated(this: SidePanelHook) {
    this.panels?.sync()
  },

  destroyed(this: SidePanelHook) {
    this.panels?.cleanup()
  },
}
