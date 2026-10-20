// The side panel, which the browser alone opens and closes. Whether it is open
// lives on <html data-aside>, which the server first draws from the cookie
// written here (KeyfleetWeb.Plugs.Panels), so LiveView never patches it away.
// Where the panel covers the page (a narrower screen, and the homepage at every
// width), it opens only when the person opens it on that page
// (<html data-aside-here>), never from the remembered state.

const yearInSeconds = 60 * 60 * 24 * 365
const cookie = "keyfleet_aside"

// Closed is the server's default; only open is kept.
function remember(value: "open" | "closed") {
  const secure = window.location.protocol === "https:" ? "; Secure" : ""
  const age = value === "open" ? yearInSeconds : 0
  document.cookie = `${cookie}=${value}; Path=/; Max-Age=${age}; SameSite=Lax${secure}`
}

const root = () => document.documentElement
const asideElement = () => document.getElementById("shell-aside")
const covering = window.matchMedia("(max-width: 63.99rem)")
const covers = () => covering.matches || asideElement()?.dataset.covers !== undefined
export const asideOpen = () =>
  root().dataset.aside === "open" && (!covers() || root().dataset.asideHere !== undefined)

/**
 * Wires the side panel inside `shell`, the element holding the header and the
 * panel. Returns `sync`, to run after every LiveView update, and `cleanup`.
 */
export function installShellPanels(shell: HTMLElement) {
  const aside = () => shell.querySelector<HTMLElement>("#shell-aside")
  const asideButton = () => shell.querySelector<HTMLButtonElement>("#shell-aside-button")

  // The panel's own button and the account name in the header both open it.
  const sync = () => {
    shell.querySelectorAll("[data-aside-toggle]").forEach(toggle =>
      toggle.setAttribute("aria-expanded", String(asideOpen())))
  }

  const setAside = (open: boolean) => {
    const value = open ? "open" : "closed"
    root().dataset.aside = value
    if (open) root().dataset.asideHere = ""
    else delete root().dataset.asideHere
    remember(value)
    sync()

    // Opened, focus moves into it, so Escape closes it and returns focus to the
    // button that opened it, and what it shows is read again.
    if (!open) return
    aside()?.focus()
    aside()
      ?.querySelectorAll("[data-read-on-open]")
      .forEach(reader => reader.dispatchEvent(new CustomEvent("ash:aside-opened")))
  }

  const onClick = (event: MouseEvent) => {
    const target = event.target instanceof Element ? event.target : null
    if (!target) return

    if (target.closest("[data-aside-toggle]")) return setAside(!asideOpen())
    // A page's own Pair New Agent button opens the panel, and leaves it open.
    if (target.closest("[data-aside-open]")) return setAside(true)
    // Where the panel covers the page, a link inside it closes it.
    if (covers() && target.closest("#shell-aside a")) setAside(false)
  }

  const onKeydown = (event: KeyboardEvent) => {
    if (event.key === "Escape" && !event.defaultPrevented && asideOpen() && aside()?.contains(document.activeElement)) {
      event.preventDefault()
      setAside(false)
      asideButton()?.focus()
    }
  }

  shell.addEventListener("click", onClick)
  document.addEventListener("keydown", onKeydown)
  covering.addEventListener("change", sync)
  sync()

  // A link from a page without the panel arrives with the panel's section in
  // its address and opens the panel on it.
  if (window.location.hash === "#shell-pairing" && shell.querySelector("#shell-pairing"))
    setAside(true)

  return {
    sync,
    cleanup: () => {
      shell.removeEventListener("click", onClick)
      document.removeEventListener("keydown", onKeydown)
      covering.removeEventListener("change", sync)
    },
  }
}
