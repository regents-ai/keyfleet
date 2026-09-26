import {afterEach, expect, it, vi} from "vitest"

import {ModalDialog, openerOf, stepTab} from "../js/hooks/modal_dialog"
import {forgetPress, notePress} from "../js/hooks/motion/shared"

// Vitest here runs without a document, so the page and the dialog are the
// small surfaces the hook touches.
type Listener = (event?: unknown) => void

function control(id: string) {
  return {id, focus: vi.fn(), click: vi.fn()}
}

function mountDialog(dataset: Record<string, string>, page: Record<string, ReturnType<typeof control>> = {}) {
  const listeners = new Map<string, Listener>()
  const title = {focus: vi.fn()}
  const dialog = {
    open: false,
    modal: false,
    returnValue: "",
    dataset,
    scrollTop: 40,
    showModal: vi.fn(() => {
      dialog.open = true
      dialog.modal = true
    }),
    show: vi.fn(() => {
      dialog.open = true
      dialog.modal = false
    }),
    close: vi.fn(() => {
      dialog.open = false
    }),
    matches: (selector: string) => selector === ":modal" && dialog.modal,
    querySelector: (selector: string) => (selector === "[data-modal-title]" ? title : null),
    querySelectorAll: () => [],
    addEventListener: vi.fn((name: string, listener: Listener) => listeners.set(name, listener)),
  }
  const back = vi.fn()
  vi.stubGlobal("history", {back})
  vi.stubGlobal("document", {
    activeElement: page.active ?? null,
    body: {},
    getElementById: (id: string) => Object.values(page).find(opened => opened.id === id) ?? null,
  })
  const pushEvent = vi.fn()
  const hook = {el: dialog, pushEvent}
  ModalDialog.mounted!.call(hook)

  const closeBy = (returnValue = "") => {
    dialog.open = false
    dialog.returnValue = returnValue
    listeners.get("close")?.()
  }
  const fire = (name: string, event?: unknown) => listeners.get(name)?.(event)
  return {dialog, hook, title, pushEvent, back, closeBy, fire}
}

afterEach(() => {
  vi.unstubAllGlobals()
  forgetPress()
})

it("opens as a modal with its title focused", () => {
  const {dialog, title} = mountDialog({close: "replace", closeEvent: "close_key", shown: "12"})

  expect(dialog.showModal).toHaveBeenCalledOnce()
  expect(title.focus).toHaveBeenCalledOnce()
})

it("goes back when the page opened it", () => {
  const {closeBy, back, pushEvent} = mountDialog({close: "back", closeEvent: "close_key"})

  closeBy()

  expect(back).toHaveBeenCalledOnce()
  expect(pushEvent).not.toHaveBeenCalled()
})

it("asks the page to close it in place when the visitor arrived on it", () => {
  const {closeBy, back, pushEvent} = mountDialog({close: "replace", closeEvent: "close_key"})

  closeBy()

  expect(pushEvent).toHaveBeenCalledWith("close_key", {})
  expect(back).not.toHaveBeenCalled()
})

it("presses the control a closing button names, and leaves focus there", () => {
  const buy = control("buy-key-button")
  const opener = control("fleet-key-link-21")
  const {closeBy, hook} = mountDialog({close: "back", closeEvent: "close_key"}, {active: opener, buy})

  closeBy("buy-key-button")
  ModalDialog.destroyed!.call(hook)

  expect(buy.click).toHaveBeenCalledOnce()
  expect(buy.focus).toHaveBeenCalled()
  expect(opener.focus).not.toHaveBeenCalled()
})

it("hands focus back to whatever opened it once it has gone", () => {
  const opener = control("fleet-key-link-12")
  const {hook} = mountDialog({close: "back", closeEvent: "close_key"}, {active: opener})

  ModalDialog.destroyed!.call(hook)

  expect(opener.focus).toHaveBeenCalledOnce()
})

it("lets the sign-in window above it be used, and is modal again on a press back inside", () => {
  const {dialog, fire, pushEvent, back} = mountDialog({close: "back", closeEvent: "close_key"})
  const signIn = {closest: (selector: string) => (selector.includes("sign-in") ? {} : null)}

  fire("click", {target: signIn})
  expect(dialog.close).toHaveBeenCalledOnce()
  expect(dialog.show).toHaveBeenCalledOnce()
  expect(dialog.matches(":modal")).toBe(false)

  // The close that came with the switch, and the one with the switch back,
  // leave the dialog where it is.
  fire("close")
  fire("pointerdown")
  fire("close")
  expect(dialog.matches(":modal")).toBe(true)
  expect(dialog.open).toBe(true)
  expect(back).not.toHaveBeenCalled()
  expect(pushEvent).not.toHaveBeenCalled()
})

it("focuses its title again when it comes to show another key", () => {
  const {dialog, hook, title} = mountDialog({close: "back", closeEvent: "close_key", shown: "12"})

  ModalDialog.updated!.call(hook)
  expect(title.focus).toHaveBeenCalledOnce()

  dialog.dataset.shown = "3"
  ModalDialog.updated!.call(hook)
  expect(title.focus).toHaveBeenCalledTimes(2)
  expect(dialog.scrollTop).toBe(0)
})

it("steps Tab and Shift+Tab through the dialog's controls, going round at either end", () => {
  const [title, first, middle, last] = ["title", "first", "middle", "last"].map(
    id => control(id) as unknown as HTMLElement,
  )
  const controls = [first, middle, last]
  const tab = (shiftKey: boolean) => ({key: "Tab", shiftKey, preventDefault: vi.fn()}) as unknown as KeyboardEvent

  const fromTitle = tab(false)
  stepTab(fromTitle, controls, title)
  expect(first.focus).toHaveBeenCalledOnce()
  expect(fromTitle.preventDefault).toHaveBeenCalledOnce()

  stepTab(tab(false), controls, first)
  expect(middle.focus).toHaveBeenCalledOnce()

  stepTab(tab(false), controls, last)
  expect(first.focus).toHaveBeenCalledTimes(2)

  stepTab(tab(true), controls, first)
  expect(last.focus).toHaveBeenCalledOnce()

  stepTab(tab(true), controls, title)
  expect(last.focus).toHaveBeenCalledTimes(2)

  const other = {key: "Enter", shiftKey: false, preventDefault: vi.fn()} as unknown as KeyboardEvent
  stepTab(other, controls, first)
  expect(other.preventDefault).not.toHaveBeenCalled()
})

it("names the control just pressed as the opener, and else the one with focus", () => {
  const body = {}
  const map = {id: "key-map-fibonacci_cascade"} as Element
  notePress({target: {closest: () => ({id: "fleet-key-link-7"})}, detail: 1} as unknown as MouseEvent)

  expect(openerOf(map, body as Element)).toBe("fleet-key-link-7")

  forgetPress()
  expect(openerOf(map, body as Element)).toBe("key-map-fibonacci_cascade")
  expect(openerOf(body as Element, body as Element)).toBeUndefined()
})
