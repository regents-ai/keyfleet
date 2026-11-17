import type {Hook} from "../hook_composition"

type ScheduleCardHook = {el: HTMLElement}

/**
 * Schedule on a fleet's page (`KeyfleetWeb.Components.ScheduleCard`), which
 * its person may put away for that fleet. Only this browser remembers it,
 * under the card's `data-kept-as`; the page draws the card hidden and this
 * shows it unless it was put away, so it never shows for a moment first. A
 * browser that keeps nothing shows it again on its next page, and the Agents
 * page shows it always.
 */
function putAway(key: string) {
  try {
    return localStorage.getItem(key) === "dismissed"
  } catch {
    return false
  }
}

function keep(key: string) {
  try {
    localStorage.setItem(key, "dismissed")
  } catch {
    // Shown again on the next page.
  }
}

export const ScheduleCard: Hook = {
  mounted(this: ScheduleCardHook) {
    const key = this.el.dataset.keptAs!
    this.el.hidden = putAway(key)

    this.el.querySelector("[data-dismiss]")?.addEventListener("click", () => {
      keep(key)
      this.el.hidden = true
    })
  },
}
