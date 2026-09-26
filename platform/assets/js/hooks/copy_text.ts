import type {Hook} from "../hook_composition"
import {deny} from "./motion/press"

type CopyTextHook = Hook & {
  el: HTMLElement
  cleanup?: () => void
}

/**
 * A button that copies its `data-copy-text` and says so for a moment. With
 * `data-copy-status` naming a status element, it also says "Copied" there, for
 * screen readers.
 */
export const CopyText: Hook = {
  mounted(this: CopyTextHook) {
    const button = this.el
    const label = button.textContent
    const status = document.getElementById(button.dataset.copyStatus ?? "")
    let timer: number | undefined

    const restore = () => {
      button.textContent = label
      if (status) status.textContent = ""
      timer = undefined
    }
    const click = async () => {
      const text = button.dataset.copyText
      if (!text) return
      try {
        await navigator.clipboard.writeText(text)
      } catch {
        deny(button)
        return
      }
      button.textContent = "Copied"
      if (status) status.textContent = "Copied"
      window.clearTimeout(timer)
      timer = window.setTimeout(restore, 1500)
    }

    button.addEventListener("click", click)
    this.cleanup = () => {
      window.clearTimeout(timer)
      button.removeEventListener("click", click)
    }
  },

  destroyed(this: CopyTextHook) {
    this.cleanup?.()
  },
}
