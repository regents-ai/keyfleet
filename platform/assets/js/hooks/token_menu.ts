import type {Hook} from "../hook_composition"

type TokenMenuHook = {el: HTMLDetailsElement; cleanup?: () => void}

/**
 * The crown's $REGENT menu, as regents.sh's works. The native details element
 * opens and shuts on a press, a tap or the keyboard; a mouse also opens it on
 * hover. It shuts when the mouse leaves it with nothing inside focused, when
 * focus leaves it, on a press anywhere else, and on Escape, which hands focus
 * back to the crown.
 */
export const TokenMenu: Hook = {
  mounted(this: TokenMenuHook) {
    const menu = this.el
    const summary = menu.querySelector("summary")
    const close = () => {
      menu.open = false
    }
    const enter = (event: PointerEvent) => {
      if (event.pointerType === "mouse") menu.open = true
    }
    const leave = () => {
      if (!menu.contains(document.activeElement)) close()
    }
    const blur = (event: FocusEvent) => {
      if (!(event.relatedTarget instanceof Node) || !menu.contains(event.relatedTarget)) close()
    }
    const outside = (event: PointerEvent) => {
      if (event.target instanceof Node && !menu.contains(event.target)) close()
    }
    const keydown = (event: KeyboardEvent) => {
      if (event.key === "Escape" && menu.open) {
        event.preventDefault()
        close()
        summary?.focus()
      }
    }
    menu.addEventListener("pointerenter", enter)
    menu.addEventListener("pointerleave", leave)
    menu.addEventListener("focusout", blur)
    document.addEventListener("pointerdown", outside)
    document.addEventListener("keydown", keydown)
    this.cleanup = () => {
      menu.removeEventListener("pointerenter", enter)
      menu.removeEventListener("pointerleave", leave)
      menu.removeEventListener("focusout", blur)
      document.removeEventListener("pointerdown", outside)
      document.removeEventListener("keydown", keydown)
    }
  },
  destroyed(this: TokenMenuHook) {
    this.cleanup?.()
  },
}
