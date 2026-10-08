import type {Hook} from "../hook_composition"
import {offerLiveTools} from "../page_tools"

type LiveToolsHook = Hook & {
  el: HTMLElement
  pushEvent(event: string, payload: unknown): Promise<unknown>
  tools?: AbortController
}

/**
 * The tools named in the element's `data-webmcp-tools`, offered while it is on
 * the page. Each call goes to the page's server as "page_tool", which answers
 * it as the person signed in on the page.
 */
export const LiveTools: Hook = {
  mounted(this: LiveToolsHook) {
    this.tools = offerLiveTools(this.el, (tool, input) => this.pushEvent("page_tool", {tool, input}))
  },

  destroyed(this: LiveToolsHook) {
    this.tools?.abort()
  },
}
