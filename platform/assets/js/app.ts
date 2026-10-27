import "../css/app.css"
import "../vendor/regent_ui/tip.mjs"

// Asks before any element carrying data-confirm acts, such as ending a poll.
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/keyfleet"

import {composeHooks, type Hook} from "./hook_composition"
import {
  browserCsrfToken,
  holdAdoptionWhileLeaving,
  holdSocketDuringCookieRotation,
  installAccountAuthLazyLoader,
  installCrossTabCsrf,
  retireRefusedSession,
  type PinnedSocket,
} from "./auth_lazy"
import {
  brandForShellApp,
  reconcileShellState,
  shellDestinationChanged,
  type ShellState,
} from "./shell_state"
import {installCopyButtons} from "./copy_buttons"
import {installPageProgress} from "./page_progress"
import {installPublicTools} from "./public_tools"
import {installShellPanels} from "./shell_panels"
import {installVitals} from "./vitals"
import {installLaunchSteps} from "./launch_steps"
import {AccountWallets} from "./hooks/account_wallets"
import {Countdown} from "./hooks/countdown"
import {FleetTabs} from "./hooks/fleet_tabs"
import {FleetPreview} from "./hooks/fleet_preview"
import {FleetSea, HarbourSea} from "./hooks/harbour_sea"
import {PlacesChart} from "./hooks/places_chart"
import {HexField, NextKeyCard} from "./hooks/home_hero"
import {HolographicCard} from "./hooks/holographic_card"
import {KeyCards} from "./hooks/key_cards"
import {KeyCardTurn} from "./hooks/key_card"
import {KeyMap} from "./hooks/key_map"
import {LocalTime} from "./hooks/local_time"
import {ModalDialog, watchPresses} from "./hooks/modal_dialog"
import {OnchainSteps} from "./hooks/onchain_steps"
import {PanelAgents} from "./hooks/panel_agents"
import {MotionCount, MotionList, MotionRefusal} from "./hooks/motion/moments"
import {MotionCascade, MotionTabs, ShellViews} from "./hooks/motion/reveals"
import {SidePanel} from "./hooks/side_panel"
import {TokenMenu} from "./hooks/token_menu"
import {VerifiedConnections} from "./hooks/verified_connections"
import {mountMotion} from "./motion"
import {installVisitLog} from "./visit_log"

// First, so an error anywhere below is reported too.
installVisitLog()

type ShellHook = Hook & {
  el: HTMLElement
  cleanup?: () => void
  panels?: ReturnType<typeof installShellPanels>
  shellState?: ShellState
  restoreState?: () => void
}

let cachedShellState: ShellState | undefined

// The colour theme, light until the visitor chooses. A press chooses the
// opposite of the theme showing and writes it to the cookie the
// server reads, so the next page is drawn in it. The switch names the theme
// showing by itself, so nothing here rewrites its words.
const themeCookie = "regent_theme"
const themeMaxAge = 60 * 60 * 24 * 365
type Theme = "light" | "dark"
const themeColors: Record<Theme, string> = {dark: "#161616", light: "#e5e3d2"}

// The visitor's choice, light until they choose.
function chosenTheme(): Theme {
  const prefix = `${themeCookie}=`
  const value = document.cookie
    .split("; ")
    .find(cookie => cookie.startsWith(prefix))
    ?.slice(prefix.length)

  return value === "dark" ? "dark" : "light"
}

// Live navigation keeps the document, so each page restates its theme.
function syncTheme() {
  const theme = chosenTheme()
  document.documentElement.dataset.theme = theme
  document.querySelector('meta[name="color-scheme"]')?.setAttribute("content", theme)
  document.querySelector('meta[name="theme-color"]')?.setAttribute("content", themeColors[theme])
}

document.addEventListener("click", event => {
  if (!(event.target instanceof Element) || !event.target.closest("[data-theme-toggle]")) return
  const theme: Theme = chosenTheme() === "dark" ? "light" : "dark"
  const secure = window.location.protocol === "https:" ? "; Secure" : ""
  document.cookie = `${themeCookie}=${theme}; Path=/; Max-Age=${themeMaxAge}; SameSite=Lax${secure}`
  syncTheme()
})

window.addEventListener("phx:page-loading-stop", syncTheme)
window.addEventListener("popstate", syncTheme)
window.addEventListener("pageshow", syncTheme)

// Before the lazy imports below can hold this module, so the page's first
// pageshow registers the browser tools.
installPublicTools()

const shellBehavior: Hook = {
  mounted(this: ShellHook) {
    const shell = this.el
    const root = document.documentElement

    const initialState: ShellState = {
      routeId: shell.dataset.routeId ?? "",
      destination: shell.dataset.destination ?? "",
      menuOpen: shell.dataset.menuOpen === "true",
    }
    root.dataset.brand = brandForShellApp(shell.dataset.app)
    this.shellState = cachedShellState
      ? reconcileShellState(cachedShellState, initialState)
      : initialState

    const menuButton = () =>
      shell.querySelector<HTMLButtonElement>("#mobile-menu-button")
    const sidebar = () => shell.querySelector<HTMLElement>("#shell-sidebar")
    const scroller = () => shell.querySelector<HTMLElement>("#app-shell-scroller")
    const menuScrim = () =>
      shell.querySelector<HTMLButtonElement>("[data-shell-menu-scrim]")
    const menuFocusables = () =>
      Array.from(
        sidebar()?.querySelectorAll<HTMLElement>(
          'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
        ) ?? [],
      ).filter(element => !element.hidden && !element.inert)

    const syncMenuAccessibility = (focusMenu = false, restoreFocus = false) => {
      const menuOpen = this.shellState?.menuOpen === true
      const currentScroller = scroller()
      const currentScrim = menuScrim()
      if (currentScroller) currentScroller.inert = menuOpen
      if (currentScrim) currentScrim.hidden = !menuOpen

      if (focusMenu && menuOpen) {
        const [first] = menuFocusables()
        ;(first ?? sidebar())?.focus()
      }

      if (restoreFocus && !menuOpen) menuButton()?.focus()
    }

    const closeMenu = (restoreFocus = true) => {
      if (this.shellState) this.shellState.menuOpen = false
      this.restoreState?.()
      syncMenuAccessibility(false, restoreFocus)
    }

    this.restoreState = () => {
      const state = this.shellState
      if (!state) return

      shell.dataset.menuOpen = String(state.menuOpen)
      cachedShellState = state
      menuButton()?.setAttribute("aria-expanded", String(state.menuOpen))
      syncMenuAccessibility()
    }

    const onClick = (event: Event) => {
      const target = event.target instanceof Element ? event.target : null

      if (target?.closest("#mobile-menu-button")) {
        if (this.shellState) this.shellState.menuOpen = !this.shellState.menuOpen
        this.restoreState?.()
        syncMenuAccessibility(this.shellState?.menuOpen === true, true)
      }

      if (target?.closest("[data-shell-menu-scrim], [data-shell-menu-close]")) {
        closeMenu()
      }

      if (target?.closest("#shell-sidebar a")) closeMenu()
    }

    const onKeydown = (event: KeyboardEvent) => {
      if (event.key === "Escape" && shell.dataset.menuOpen === "true") {
        event.preventDefault()
        closeMenu()
        return
      }

      if (event.key === "Tab" && shell.dataset.menuOpen === "true") {
        const focusables = menuFocusables()
        const first = focusables.at(0)
        const last = focusables.at(-1)
        const currentSidebar = sidebar()

        if (!first || !last) {
          event.preventDefault()
          currentSidebar?.focus()
        } else if (!currentSidebar?.contains(document.activeElement)) {
          event.preventDefault()
          ;(event.shiftKey ? last : first).focus()
        } else if (event.shiftKey && document.activeElement === first) {
          event.preventDefault()
          last.focus()
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault()
          first.focus()
        }
        return
      }

      if (event.key === "Escape") {
        const openDetails = [...shell.querySelectorAll<HTMLDetailsElement>("details[open]")].at(-1)

        if (openDetails) {
          openDetails.removeAttribute("open")
          openDetails.querySelector<HTMLElement>("summary")?.focus()
          event.preventDefault()
          return
        }
      }

    }

    const onHistoryNavigation = () => {
      scroller()?.scrollTo({top: 0})
    }

    shell.addEventListener("click", onClick)
    shell.addEventListener("keydown", onKeydown)
    window.addEventListener("popstate", onHistoryNavigation)
    this.panels = installShellPanels(shell)
    this.restoreState()
    scroller()?.scrollTo({top: 0})
    shell.dataset.behaviorReady = "true"

    this.cleanup = () => {
      closeMenu(false)
      this.panels?.cleanup()
      shell.removeEventListener("click", onClick)
      shell.removeEventListener("keydown", onKeydown)
      window.removeEventListener("popstate", onHistoryNavigation)
    }
  },

  updated(this: ShellHook) {
    document.documentElement.dataset.brand = brandForShellApp(this.el.dataset.app)
    const incoming = {
      routeId: this.el.dataset.routeId ?? "",
      destination: this.el.dataset.destination ?? "",
    }

    const menuWasOpen = this.shellState?.menuOpen === true
    const shouldScroll = this.shellState
      ? shellDestinationChanged(this.shellState, incoming)
      : false
    if (this.shellState) {
      this.shellState = reconcileShellState(this.shellState, incoming)
    }
    this.restoreState?.()
    this.panels?.sync()
    if (menuWasOpen && this.shellState?.menuOpen === false) {
      this.el.querySelector<HTMLButtonElement>("#mobile-menu-button")?.focus()
    }
    this.el.dataset.behaviorReady = "true"
    // A new page starts at its top, with focus on its heading, so a screen
    // reader announces where the person has arrived.
    if (shouldScroll) {
      this.el.querySelector<HTMLElement>("#app-shell-scroller")?.scrollTo({top: 0})
      this.el.querySelector<HTMLElement>("#route-content h1")?.focus({preventScroll: true})
    }
  },

  destroyed(this: ShellHook) {
    this.cleanup?.()
  },
}

// Design composes presentation behavior here; the Ash-owned behavior remains first.
const showcaseHooks = window.location.pathname.startsWith("/showcase")
  ? (await import("./showcase")).hooks : {}
const labHooks = window.location.pathname === "/animations"
  ? (await import("./motion_lab")).hooks : {}
const hooks = {
  ...showcaseHooks,
  ...labHooks,
  ...colocatedHooks,
  AccountWallets,
  Countdown,
  FleetTabs,
  FleetPreview,
  FleetSea,
  HarbourSea,
  HexField,
  HolographicCard,
  KeyCards,
  KeyCardTurn,
  KeyMap,
  LocalTime,
  ModalDialog,
  MotionCascade,
  MotionCount,
  MotionList,
  MotionRefusal,
  MotionTabs,
  NextKeyCard,
  OnchainSteps,
  PanelAgents,
  PlacesChart,
  ShellBehavior: composeHooks(shellBehavior, ShellViews),
  SidePanel,
  TokenMenu,
  VerifiedConnections,
}
if (!browserCsrfToken()) throw new Error("Missing CSRF token")

// Phoenix's own waits between reconnect attempts, each spread from half to
// one and a half times its length. A deploy drops every open page at once;
// without the spread they all come back in the same instant and each reads
// its page again, more than the site's few database connections can answer.
const reconnectWaits = [10, 50, 100, 150, 200, 250, 500, 1000, 2000]
const spreadReconnect = (tries: number) => {
  const wait = reconnectWaits[tries - 1] ?? 5000
  return Math.round(wait / 2 + Math.random() * wait)
}

// Sign in and refresh renew the session and rotate its CSRF state, so every
// connection and reconnection reads the token the browser holds now.
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  reconnectAfterMs: spreadReconnect,
  params: () => ({_csrf_token: browserCsrfToken()}),
  hooks,
})

// Installed before the first connect, so even the page's opening attempt is
// subject to the barrier. `types.d.ts` describes only the LiveSocket surface
// this application calls, so the transport entry point is named at the cast.
holdSocketDuringCookieRotation(liveSocket.getSocket() as PinnedSocket)
holdAdoptionWhileLeaving()
// Started before the first connect, so a page rendered for a refused cookie
// holds its socket until that cookie is retired.
void retireRefusedSession()
liveSocket.connect()
installAccountAuthLazyLoader()
installCrossTabCsrf()
installCopyButtons()
installPageProgress()
installVitals()
installLaunchSteps()
watchPresses(document)
mountMotion(document)
window.liveSocket = liveSocket
