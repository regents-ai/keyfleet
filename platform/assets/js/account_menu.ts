// The account menu is a popover the browser opens and closes itself (the
// header's account button names it). Only following a link inside it, and the
// pairing window its Pair New Agent opens, are ours.

/**
 * Brings `target`, what an address's #fragment names, into view. When it holds a
 * choice, such as the pairing box's agents, focus goes to the chosen one, or the
 * first, so the keyboard starts there. Returns whether it holds one.
 */
export function arriveAt(target: HTMLElement) {
  target.scrollIntoView()
  const choices = [...target.querySelectorAll<HTMLInputElement>("input[type=radio]")]
  const choice = choices.find(radio => radio.checked) ?? choices[0]
  // Next frame: following the link, and LiveView's patch, each move focus first.
  if (choice) requestAnimationFrame(() => choice.focus({preventScroll: true}))
  return choice !== undefined
}

/** The element the address's #fragment names, such as the Agents page's pairing box. */
export const hashTarget = () => {
  const id = decodeURIComponent(window.location.hash.slice(1))
  return id ? document.getElementById(id) : null
}

const pairing = () => document.querySelector<HTMLDialogElement>("#shell-pairing")

// The window opens on the list of agents while none is chosen, with the keyboard
// on the dropdown.
const openPairing = () => {
  const dialog = pairing()
  if (!dialog || dialog.open) return
  dialog.showModal()
  const pick = dialog.querySelector<HTMLDetailsElement>("details.rg-pill-select")
  if (!pick) return
  if (!pick.querySelector("input:checked")) pick.open = true
  pick.querySelector<HTMLElement>(":scope > summary")?.focus()
}

/**
 * A page change keeps an open menu open, so a link followed from one closes it.
 * A link to a #fragment of this page changes nothing LiveView sees when the
 * address already shows it, so what it names comes into view here, every press.
 * Pair New Agent, in the account menu, on the Agents page and on Connect, opens
 * the one pairing window over the page; the menu closes first.
 */
export function installAccountMenu() {
  document.addEventListener("click", event => {
    const target = event.target instanceof Element ? event.target : null
    const pairOpener = target?.closest<HTMLElement>("[data-pair-open]")
    if (pairOpener) {
      pairOpener.closest<HTMLElement>("[popover]")?.hidePopover()
      return openPairing()
    }
    // A press on the window's own backdrop lands on the window itself.
    if (target?.closest("[data-pair-close]") || (target && target === pairing())) {
      return pairing()?.close()
    }
    const link = target?.closest<HTMLAnchorElement>("a[href]")
    if (!link) return
    link.closest<HTMLElement>("[popover]")?.hidePopover()
    // Give It a Shard, under the box once an agent pairs, leads to another page.
    if (link.closest("#shell-pairing")) pairing()?.close()
    const named = link.hash && link.pathname === window.location.pathname
      ? document.getElementById(decodeURIComponent(link.hash.slice(1)))
      : null
    if (named) arriveAt(named)
  })
}
