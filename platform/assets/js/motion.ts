/**
 * Keyfleet's standard motion on every page: a squish when something is
 * pressed, a shake when a control says it can't be used yet, and a
 * server-rendered page's headline rising in word by word.
 *
 * A live page draws its own parts again whenever it changes, so only what the
 * server drew once moves as the page opens; live parts move from their hooks.
 */
import {splitText} from "animejs"
import {byPointer, forgetPress, notePress, still} from "./hooks/motion/shared"
import {nope, squish} from "./hooks/motion/press"
import {HEADLINES} from "./hooks/motion/reveals"

const PRESSABLE = "button, summary, .rg-button, [role='button']"
// The theme switch keeps its own motion, a turning cube, and never squishes.
const OWN_MOTION = ".rg-theme-toggle"

const live = (el: Element) => el.closest("[data-phx-session]") !== null

export function mountMotion(doc: Document = document) {
  doc.addEventListener("click", notePress, true)
  doc.addEventListener("keydown", forgetPress, true)
  doc.addEventListener("click", press)

  const main = doc.querySelector("main")
  if (main === null || live(main) || still()) return

  const headline = main.querySelector("h1")
  if (headline !== null) rise(headline)
}

// The press has already reached the control and everything listening for it;
// the motion only plays alongside.
export function press(event: MouseEvent) {
  const el = (event.target as Element).closest<HTMLElement>(PRESSABLE)
  if (el === null || el.matches(OWN_MOTION) || !byPointer(event) || still()) return
  if (el.getAttribute("aria-disabled") === "true") nope(el)
  else squish(el)
}

// The words are joined back into plain text once they have risen.
function rise(headline: HTMLElement) {
  const split = splitText(headline, {words: {wrap: "clip"}})
  HEADLINES.rise(split).then(() => split.revert())
}
