/**
 * Keyfleet's standard motion on every page: a squish when something is
 * pressed, and a server-rendered page's headline rising in word by word.
 *
 * A live page draws its own parts again whenever it changes, so only what the
 * server drew once moves as the page opens; live parts move from their hooks.
 */
import {splitText} from "animejs"
import {byPointer, forgetPress, notePress, still} from "./hooks/motion/shared"
import {squish} from "./hooks/motion/press"
import {HEADLINES} from "./hooks/motion/reveals"

const PRESSABLE = "button, summary, .rg-button, [role='button']"
// The theme switch keeps its own motion, a turning cube, and never squishes.
const OWN_MOTION = ".rg-theme-toggle"
// Buttons that open the wallet or send a transaction. Only their label
// squishes: the button itself never shrinks, so a quick second press near
// its edge still lands on it.
const WALLET =
  "[data-buy-key], [data-fleet-action], [data-account-target='connect-wallet'], [data-demo-send]"

const live = (el: Element) => el.closest("[data-phx-session]") !== null

export function mountMotion() {
  document.addEventListener("click", notePress, true)
  document.addEventListener("keydown", forgetPress, true)
  window.addEventListener("popstate", forgetPress)
  document.addEventListener("click", press)

  const main = document.querySelector("main")
  if (main === null || live(main) || still()) return

  const headline = main.querySelector("h1")
  if (headline !== null) rise(headline)
}

// The press has already reached the control and everything listening for it;
// the motion only plays alongside.
export function press(event: MouseEvent) {
  const el = (event.target as Element).closest<HTMLElement>(PRESSABLE)
  if (el === null || el.matches(OWN_MOTION) || !byPointer(event) || still()) return
  const moving = el.matches(WALLET) ? el.querySelector<HTMLElement>("[data-press-label]") : el
  if (moving !== null) squish(moving)
}

// The words are joined back into plain text once they have risen.
function rise(headline: HTMLElement) {
  const split = splitText(headline, {words: {wrap: "clip"}})
  HEADLINES.rise(split).then(() => split.revert())
}
