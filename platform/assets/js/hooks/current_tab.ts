import type {Hook} from "../hook_composition"

type CurrentTabHook = {el: HTMLElement}

/**
 * A row of tabs that scrolls sideways on a narrow screen keeps the open tab
 * (`aria-current="page"`) in view, when the page opens and after each change
 * of tab. It moves only the row, never the page.
 */
function reveal(row: HTMLElement) {
  const tab = row.querySelector<HTMLElement>('[aria-current="page"]')
  if (!tab) return
  const from = tab.getBoundingClientRect().left - row.getBoundingClientRect().left
  if (from >= 0 && from + tab.offsetWidth <= row.clientWidth) return
  row.scrollLeft += from - (row.clientWidth - tab.offsetWidth) / 2
}

export const CurrentTab: Hook = {
  mounted(this: CurrentTabHook) {
    reveal(this.el)
  },

  updated(this: CurrentTabHook) {
    reveal(this.el)
  },
}
