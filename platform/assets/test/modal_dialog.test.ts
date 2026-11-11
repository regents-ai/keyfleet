import {afterEach, expect, it, vi} from "vitest"

import {ModalDialog, openerOf, stepTab, watchPresses} from "../js/hooks/modal_dialog"

// Vitest here runs without a document, so the page and the dialog are the
// small surfaces the hook touches.
type Listener = (event?: unknown) => void

function control(id: string) {
  return {id, focus: vi.fn()}
}

// What the page's window is listening for, as the dialogs listen.
const pageListeners = new Map<string, Listener[]>()
const firePage = (name: string) => (pageListeners.get(name) ?? []).forEach(listener => listener())

// Every dialog a test opened, taken away after it.
const mounted: object[] = []

function mountDialog(dataset: Record<string, string>, page: Record<string, ReturnType<typeof control>> = {}) {
  const listeners = new Map<string, Listener>()
  const title = {focus: vi.fn()}
  const body = {scrollTo: vi.fn()}
  const dialog = {
    open: false,
    modal: false,
    dataset,
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
    querySelector: (selector: string) =>
      ({"[data-modal-title]": title, ".rg-dialog__body": body})[selector] ?? null,
    querySelectorAll: () => [],
    addEventListener: vi.fn((name: string, listener: Listener) => listeners.set(name, listener)),
  }
  const back = vi.fn()
  vi.stubGlobal("history", {back})
  vi.stubGlobal("window", {
    addEventListener: (name: string, listener: Listener) =>
      pageListeners.set(name, [...(pageListeners.get(name) ?? []), listener]),
    removeEventListener: (name: string, listener: Listener) =>
      pageListeners.set(name, (pageListeners.get(name) ?? []).filter(kept => kept !== listener)),
  })
  vi.stubGlobal("document", {
    activeElement: page.active ?? null,
    body: {},
    getElementById: (id: string) => Object.values(page).find(opened => opened.id === id) ?? null,
  })
  const pushEvent = vi.fn()
  const hook = {el: dialog, pushEventTo: pushEvent}
  ModalDialog.mounted!.call(hook)
  mounted.push(hook)

  const closeBy = () => {
    dialog.open = false
    listeners.get("close")?.()
  }
  const fire = (name: string, event?: unknown) => listeners.get(name)?.(event)
  return {dialog, body, hook, title, pushEvent, back, closeBy, fire}
}

// The page-wide listeners that note each press, as `watchPresses` adds them.
const presses = new Map<string, (event?: unknown) => void>()
const listen = (type: string, listener: (event?: unknown) => void) => presses.set(type, listener)
watchPresses({addEventListener: listen, defaultView: {addEventListener: listen}} as unknown as Document)
const press = (id: string) => presses.get("click")!({target: {closest: () => ({id})}, detail: 1})

afterEach(() => {
  mounted.splice(0).forEach(hook => ModalDialog.destroyed!.call(hook))
  vi.unstubAllGlobals()
  presses.get("keydown")!()
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
  const {dialog, closeBy, back, pushEvent} = mountDialog({close: "replace", closeEvent: "close_key"})

  closeBy()

  expect(pushEvent).toHaveBeenCalledWith(dialog, "close_key", {})
  expect(back).not.toHaveBeenCalled()
})

it("hands focus back to whatever opened it once it has gone, with its ring after a key", () => {
  const opener = control("fleet-key-link-12")
  const {hook} = mountDialog({close: "back", closeEvent: "close_key"}, {active: opener})

  presses.get("keydown")!()
  ModalDialog.destroyed!.call(hook)

  expect(opener.focus).toHaveBeenCalledExactlyOnceWith({focusVisible: true})
})

it("hands focus back with no ring when a pointer closed it", () => {
  const opener = control("home-buy-key")
  const {hook} = mountDialog({close: "replace", closeEvent: "close_buy_key"}, {active: opener})

  press("home-buy-key-close")
  ModalDialog.destroyed!.call(hook)

  expect(opener.focus).toHaveBeenCalledExactlyOnceWith({focusVisible: false})
})

it("counts a click a key made, Enter on the close button, as the key's", () => {
  const opener = control("home-buy-key")
  const {hook} = mountDialog({close: "replace", closeEvent: "close_buy_key"}, {active: opener})

  presses.get("keydown")!()
  presses.get("click")!({target: {closest: () => ({id: "home-buy-key-close"})}, detail: 0})
  ModalDialog.destroyed!.call(hook)

  expect(opener.focus).toHaveBeenCalledExactlyOnceWith({focusVisible: true})
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

// Sean, 21 October 2026: after a sign-in cancelled from the Buy Key window,
// the window was left without its backdrop and the page drew over it.
it("is modal again, with focus on the button that opened sign-in, once the sign-in window has gone", () => {
  const {dialog, fire, pushEvent, back} = mountDialog({close: "replace", closeEvent: "close_buy_key"})
  const buy = {focus: vi.fn()}
  const signIn = {closest: (selector: string) => (selector.includes("sign-in") ? buy : null)}

  fire("click", {target: signIn})
  fire("close")
  expect(dialog.matches(":modal")).toBe(false)

  firePage("ash:sign-in-closed")
  fire("close")
  expect(dialog.matches(":modal")).toBe(true)
  expect(dialog.open).toBe(true)
  expect(buy.focus).toHaveBeenCalledOnce()
  expect(pushEvent).not.toHaveBeenCalled()
  expect(back).not.toHaveBeenCalled()

  // Already modal, it stays as it is.
  firePage("ash:sign-in-closed")
  expect(dialog.showModal).toHaveBeenCalledTimes(2)
  expect(buy.focus).toHaveBeenCalledOnce()
})

// A Key's page is a dialog too, with the Buy Key window above it. Left modal,
// it would keep the sign-in window out of reach.
it("steps every dialog down for sign-in, and brings them back bottom first", () => {
  const profile = mountDialog({close: "back", closeEvent: "close_key"})
  const buyKey = mountDialog({close: "replace", closeEvent: "close_buy_key"})
  const signIn = {closest: (selector: string) => (selector.includes("sign-in") ? {focus: vi.fn()} : null)}

  buyKey.fire("click", {target: signIn})
  expect(profile.dialog.matches(":modal")).toBe(false)
  expect(buyKey.dialog.matches(":modal")).toBe(false)

  firePage("ash:sign-in-closed")
  expect(profile.dialog.matches(":modal")).toBe(true)
  expect(buyKey.dialog.matches(":modal")).toBe(true)
  expect(profile.dialog.showModal.mock.invocationCallOrder.at(-1)).toBeLessThan(
    buyKey.dialog.showModal.mock.invocationCallOrder.at(-1)!,
  )
})

it("stops listening for the sign-in window once it has gone", () => {
  const {hook} = mountDialog({close: "replace", closeEvent: "close_buy_key"})
  expect(pageListeners.get("ash:sign-in-closed")).toHaveLength(1)

  ModalDialog.destroyed!.call(hook)
  mounted.splice(0)
  expect(pageListeners.get("ash:sign-in-closed")).toEqual([])
})

it("focuses its title again when it comes to show another key", () => {
  const {dialog, body, hook, title} = mountDialog({close: "back", closeEvent: "close_key", shown: "12"})

  ModalDialog.updated!.call(hook)
  expect(title.focus).toHaveBeenCalledOnce()

  dialog.dataset.shown = "3"
  ModalDialog.updated!.call(hook)
  expect(title.focus).toHaveBeenCalledTimes(2)
  expect(body.scrollTo).toHaveBeenCalledExactlyOnceWith({top: 0})
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
  press("fleet-key-link-7")

  expect(openerOf(map, body as Element)).toBe("fleet-key-link-7")

  presses.get("keydown")!()
  expect(openerOf(map, body as Element)).toBe("key-map-fibonacci_cascade")
  expect(openerOf(body as Element, body as Element)).toBeUndefined()
})

it("forgets the control just pressed on going back or forward", () => {
  const map = {id: "key-map-fibonacci_cascade"} as Element
  press("fleet-key-link-7")
  presses.get("popstate")!()

  expect(openerOf(map, {} as Element)).toBe("key-map-fibonacci_cascade")
})
