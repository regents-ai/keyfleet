import type {Hook} from "../hook_composition"
import {pressedControl} from "./motion/shared"

interface ModalDialogHook {
  el: HTMLDialogElement
  pushEvent(event: string, payload: Record<string, never>): void
  opener?: string
  shown?: string
}

const focusable =
  "a[href], button:not([disabled]), textarea:not([disabled]), input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex='-1'])"

// The control that opened the dialog: the one just pressed, or else the one
// with focus.
export function openerOf(active: Element | null, body: Element | null) {
  return pressedControl() ?? (active && active !== body && active.id ? active.id : undefined)
}

// Tab and Shift+Tab step through the dialog's controls and go round at either
// end, never leaving it. Every control is a stop, as Safari would otherwise
// pass over links and buttons and find its way out.
export function stepTab(event: KeyboardEvent, controls: HTMLElement[], active: Element | null) {
  if (event.key !== "Tab" || controls.length === 0) return
  event.preventDefault()
  const at = controls.indexOf(active as HTMLElement)
  const step = event.shiftKey ? -1 : 1
  const from = at === -1 && event.shiftKey ? 0 : at
  controls[(from + step + controls.length) % controls.length].focus()
}

// A <dialog> the page opens as a modal for as long as it is in the page. It
// opens with focus on its title, and on its title again when it comes to show
// something else. Closing it asks the page to take it away: by going back when
// `data-close` is "back", or else by sending `data-close-event`. A button that
// closes it may name, as its value, a control on the page to press next. Once
// it has gone, focus returns to whatever opened it. Signing in from inside it
// lets the sign-in window above it be used, and a press back inside makes it
// modal again.
export const ModalDialog: Hook = {
  mounted(this: ModalDialogHook) {
    const dialog = this.el
    this.opener = openerOf(document.activeElement, document.body)
    this.shown = dialog.dataset.shown

    dialog.addEventListener("close", () => {
      // Closed only to be shown again, modal or not.
      if (dialog.open) return
      const next = dialog.returnValue && document.getElementById(dialog.returnValue)
      if (next) {
        this.opener = next.id
        next.focus()
        next.click()
      }
      if (dialog.dataset.close === "back") history.back()
      else if (dialog.dataset.closeEvent) this.pushEvent(dialog.dataset.closeEvent, {})
    })

    dialog.addEventListener("keydown", event => stepTab(event, visibleControls(dialog), document.activeElement))

    dialog.addEventListener("click", event => {
      if (!(event.target as Element).closest("[data-account-target='sign-in']")) return
      if (!dialog.matches(":modal")) return
      dialog.close()
      dialog.show()
    })

    dialog.addEventListener("pointerdown", () => {
      if (dialog.matches(":modal")) return
      dialog.close()
      dialog.showModal()
    })

    if (!dialog.open) dialog.showModal()
    focusTitle(dialog)
  },

  updated(this: ModalDialogHook) {
    if (this.el.dataset.shown === this.shown) return
    this.shown = this.el.dataset.shown
    this.el.scrollTop = 0
    this.el.querySelector<HTMLElement>("[data-modal-scroll]")?.scrollTo({top: 0})
    focusTitle(this.el)
  },

  destroyed(this: ModalDialogHook) {
    if (this.opener) document.getElementById(this.opener)?.focus()
  },
}

function focusTitle(dialog: HTMLDialogElement) {
  dialog.querySelector<HTMLElement>("[data-modal-title]")?.focus()
}

function visibleControls(dialog: HTMLDialogElement) {
  return Array.from(dialog.querySelectorAll<HTMLElement>(focusable)).filter(
    control => control.getClientRects().length > 0,
  )
}
