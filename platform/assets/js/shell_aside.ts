// The app shell's side panel: the account, its agents and Pair New Agent. The
// browser alone opens and closes it. Its state lives on <html data-aside>, which
// the server first draws from the cookie written here (KeyfleetWeb.Plugs.Panels),
// so LiveView never patches it away. Below a wide screen, where the panel covers
// the page, it opens only when the person opens it on that page
// (<html data-aside-here>), never from the remembered state.

const cookie = "keyfleet_aside"
const yearInSeconds = 60 * 60 * 24 * 365

// Only "open" is kept; closed is the server's default.
function remember(value: string) {
  const secure = window.location.protocol === "https:" ? "; Secure" : ""
  const age = value === "open" ? yearInSeconds : 0
  document.cookie = `${cookie}=${value}; Path=/; Max-Age=${age}; SameSite=Lax${secure}`
}

const root = () => document.documentElement
const covering = window.matchMedia("(max-width: 63.99rem)")
export const asideOpen = () =>
  root().dataset.aside === "open" && (!covering.matches || root().dataset.asideHere !== undefined)

/**
 * Wires the side panel inside `shell`. Returns `sync`, to run after every
 * LiveView update, and `cleanup`.
 */
export function installShellAside(shell: HTMLElement) {
  const aside = () => shell.querySelector<HTMLElement>("#shell-aside")
  const toggle = () => shell.querySelector<HTMLElement>("[data-aside-toggle]")

  // The account's name in the header opens and closes it.
  const sync = () => {
    shell.querySelectorAll("[data-aside-toggle]").forEach(button =>
      button.setAttribute("aria-expanded", String(asideOpen())))
  }

  const setAside = (open: boolean) => {
    const value = open ? "open" : "closed"
    root().dataset.aside = value
    if (open) root().dataset.asideHere = ""
    else delete root().dataset.asideHere
    remember(value)
    sync()

    // Opened, focus moves into it, so Escape closes it and returns focus to the
    // name that opened it, and what it shows is read again.
    if (!open) return
    aside()?.focus()
    aside()
      ?.querySelectorAll("[data-read-on-open]")
      .forEach(reader => reader.dispatchEvent(new CustomEvent("keyfleet:aside-opened")))
  }

  const onClick = (event: MouseEvent) => {
    const target = event.target instanceof Element ? event.target : null
    if (!target) return

    if (target.closest("[data-aside-toggle]")) return setAside(!asideOpen())
    // A page's own Pair New Agent button opens the panel, and leaves it open.
    if (target.closest("[data-aside-open]")) return setAside(true)
    // Where the panel covers the page, a link inside it closes it.
    if (covering.matches && target.closest("#shell-aside a")) setAside(false)
  }

  // Escape closes what the page opened inside the panel first, such as a menu.
  const onKeydown = (event: KeyboardEvent) => {
    if (event.defaultPrevented) return
    if (event.key === "Escape" && asideOpen() && aside()?.contains(document.activeElement)) {
      event.preventDefault()
      setAside(false)
      toggle()?.focus()
    }
  }

  shell.addEventListener("click", onClick)
  document.addEventListener("keydown", onKeydown)
  covering.addEventListener("change", sync)
  sync()

  // A link from a page without the panel arrives with the panel's section in its
  // address and opens the panel on it.
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
