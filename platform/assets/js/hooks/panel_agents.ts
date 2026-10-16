import type {Hook} from "../hook_composition"
import {asideOpen} from "../shell_aside"

interface PanelAgentsHook {
  el: HTMLElement
  read?: () => void
  pushEventTo(target: HTMLElement, event: string, payload: object): void
}

// The side panel's agents read what each one last did only while someone can
// see them: when the page arrives with the panel open, and each time it opens
// (`keyfleet:aside-opened`, from `installShellAside`).
export const PanelAgents: Hook = {
  mounted(this: PanelAgentsHook) {
    this.read = () => this.pushEventTo(this.el, "read_last_actions", {})
    this.el.addEventListener("keyfleet:aside-opened", this.read)
    if (asideOpen()) this.read()
  },

  destroyed(this: PanelAgentsHook) {
    if (this.read) this.el.removeEventListener("keyfleet:aside-opened", this.read)
  },
}
