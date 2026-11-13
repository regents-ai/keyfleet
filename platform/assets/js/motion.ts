/**
 * The standard motion on every page: a squish when something is pressed, a
 * shake when the answer is no, and panels that slide or pop open. The version
 * of each is named in `KeyfleetWeb.Motion` and every version that was tried is
 * kept in the template's motion lab at /animations. Every page this runs on is
 * live and draws its own parts again whenever it changes, so the parts that
 * move as a page opens move from their hooks.
 *
 * Nothing here waits for, stops or repeats a press: a wallet button reaches
 * the wallet the moment it is pressed, and the motion plays alongside.
 */
import {nope, squish} from "./hooks/motion/press"
import {byPointer, lastInputByPointer, still, watchInput} from "./hooks/motion/shared"
import {backdrop, drawer, list, menu, settle, sheet, unlist} from "./hooks/motion/slides"

// A menu's summary is its button; other summaries open disclosures in the
// page's own flow and stay still. A switch moves its own knob, and the lab's
// presses, named with `data-press`, answer for themselves.
const PRESSABLE =
  ":is(button, .rg-button, [role='button'], summary:has(~ [data-panel='menu'])):not([role='switch'], [data-press])"

export function mountMotion(doc: Document) {
  watchInput(doc)
  doc.addEventListener("click", press)
  doc.addEventListener("toggle", toggle, true)
}

// By the time a press reaches the document, the page has already acted on
// it, so a control that opens a drawer says it is open. A button that says it
// cannot be used yet shakes its head instead of squishing. A wallet button
// squishes only its `data-press-label`, so the button itself never shrinks
// and a quick second press near its edge still lands on it.
export function press(event: MouseEvent) {
  if (!(event.target instanceof Element) || !byPointer(event)) return
  const control = event.target.closest(PRESSABLE)
  if (control === null || still(control)) return

  if (control.getAttribute("aria-disabled") === "true") {
    nope(control)
    return
  }

  squish(control.querySelector("[data-press-label]") ?? control)

  if (control.getAttribute("aria-expanded") !== "true") return
  const panel = event.target.ownerDocument.getElementById(control.getAttribute("aria-controls") ?? "")
  if (panel?.dataset.panel !== "drawer") return

  drawer(panel)
  const shade = panel.parentElement?.querySelector(":scope > [data-backdrop]")
  if (shade) backdrop(shade)
}

// A dialog rises as a sheet, a header menu pops open and a dropdown's list
// drops in, and leaves again when it closes. A page that redraws an open one
// closes and reopens it within one moment, which reports it as having been
// open all along, so it does not move again.
function toggle(event: Event) {
  if (!(event instanceof ToggleEvent) || !(event.target instanceof HTMLElement)) return
  const {target} = event
  const moves = lastInputByPointer() && !still(target)
  if (event.newState === "closed") {
    if (moves) close(target)
    return
  }
  if (event.oldState !== "closed") return

  if (moves) open(target)
  else openStill(target)
}

function open(target: HTMLElement) {
  if (target instanceof HTMLDialogElement) return sheet(target)
  const panel = detailsPanel(target)
  if (panel?.dataset.panel === "menu") return menu(panel)
  if (panel?.dataset.panel === "list") return list(panel)
}

function openStill(target: HTMLElement) {
  const panel = detailsPanel(target)
  if (panel?.dataset.panel === "list") settle(panel)
}

function close(target: HTMLElement) {
  const panel = detailsPanel(target)
  if (panel?.dataset.panel === "list") unlist(panel)
}

const detailsPanel = (target: HTMLElement) =>
  target instanceof HTMLDetailsElement ? target.querySelector<HTMLElement>(":scope > [data-panel]") : null
