import type {Hook} from "../hook_composition"

type PageCommands = {
  setAttribute(el: HTMLElement, attr: string, val: string): void
  removeAttribute(el: HTMLElement, attr: string): void
}

type OpenWhenWideHook = Hook & {
  el: HTMLElement
  js(): PageCommands
}

/** The width from which the panel starts open; narrower, it starts closed. */
const WIDE = "(min-width: 64rem)"

/**
 * A side panel the page draws open, and its styles keep out of sight on a
 * narrow screen until this runs. On a narrow screen it closes the panel and
 * says so on its button, the element whose id is `data-toggle`; either way the panel's
 * `hidden` attribute then decides whether it shows. The changes are made as
 * page commands, so they stay while the page updates.
 */
export const OpenWhenWide: Hook = {
  mounted(this: OpenWhenWideHook) {
    const panel = this.el
    const commands = this.js()

    if (!window.matchMedia(WIDE).matches) {
      const toggle = document.getElementById(panel.dataset.toggle as string) as HTMLElement
      commands.setAttribute(panel, "hidden", "hidden")
      commands.setAttribute(toggle, "aria-expanded", "false")
    }
    commands.removeAttribute(panel, "data-wide-only")
  },
}
