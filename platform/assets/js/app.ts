import "../css/app.css"
import "../vendor/regent_ui/confirm.mjs"
import "../vendor/regent_ui/tip.mjs"

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
import {installAgentMessage} from "./agent_message"
import {installCopyButtons} from "./copy_buttons"
import {installPageProgress} from "./page_progress"
import {installPublicTools} from "./public_tools"
import {arriveAt, hashTarget, installAccountMenu} from "./account_menu"
import {installVitals} from "./vitals"
import {installLaunchSteps} from "./launch_steps"
import {spreadReconnect} from "./reconnect"
import {AccountWallets} from "./hooks/account_wallets"
import {AtlasBlocks} from "./hooks/atlas_blocks"
import {AtlasField} from "./hooks/atlas_field"
import {AtlasHeat} from "./hooks/atlas_heat"
import {AtlasRiver} from "./hooks/atlas_river"
import {Countdown} from "./hooks/countdown"
import {FleetTabs} from "./hooks/fleet_tabs"
import {FleetPreview} from "./hooks/fleet_preview"
import {HarbourSea} from "./hooks/harbour_sea"
import {PlacesChart} from "./hooks/places_chart"
import {ScrollRow} from "./hooks/scroll_row"
import {HexField, NextKeyCard} from "./hooks/home_hero"
import {HolographicCard} from "./hooks/holographic_card"
import {KeyCards} from "./hooks/key_cards"
import {KeyCardTurn} from "./hooks/key_card"
import {KeyMap} from "./hooks/key_map"
import {LocalTime} from "./hooks/local_time"
import {ModalDialog, watchPresses} from "./hooks/modal_dialog"
import {OnchainSteps} from "./hooks/onchain_steps"
import {MenuAgents} from "./hooks/menu_agents"
import {MotionCount, MotionList, MotionRefusal, MotionStamp, MotionTick} from "./hooks/motion/moments"
import {MotionCascade, MotionTabs, ShellViews} from "./hooks/motion/reveals"
import {ThemeSwitch} from "./hooks/theme_switch"
import {TokenMenu} from "./hooks/token_menu"
import {TreeCanvas} from "./hooks/tree_canvas"
import {ValueCard} from "./hooks/value_card"
import {VerifiedConnections} from "./hooks/verified_connections"
import {Worldline} from "./hooks/worldline"
import {mountMotion} from "./motion"
import {installVisitLog} from "./visit_log"
import {syncTheme} from "./theme"

// First, so an error anywhere below is reported too.
installVisitLog()

type ShellHook = Hook & {
  el: HTMLElement
  cleanup?: () => void
  shellState?: ShellState
  restoreState?: () => void
}

let cachedShellState: ShellState | undefined

// A room opened from its fleet's hall takes the keyboard to its name, and on
// a phone, where the hall stacks above the room, brings the name into view.
// Any other step within the page leaves the keyboard where it is.
let shownRoom = new URLSearchParams(window.location.search).get("room")

function revealRoom(event: Event) {
  const room = new URLSearchParams(window.location.search).get("room")
  const opened = room !== null && room !== shownRoom
  shownRoom = room
  if (!opened || (event as CustomEvent<{kind?: string}>).detail?.kind !== "patch") return
  const title = document.getElementById("rooms-thread-title")
  if (!title) return
  const {top, bottom} = title.getBoundingClientRect()
  const inView = top >= 0 && bottom <= window.innerHeight
  title.focus({preventScroll: inView})
  if (!inView) title.scrollIntoView({block: "start"})
}

// Live navigation keeps the document, so each page restates its theme
// (theme.ts); every theme switch follows what it shows.
window.addEventListener("phx:page-loading-stop", syncTheme)
window.addEventListener("phx:page-loading-stop", revealRoom)
window.addEventListener("popstate", syncTheme)
window.addEventListener("pageshow", syncTheme)

// Before the lazy imports below can hold this module, so the page's first
// pageshow registers the browser tools.
installPublicTools()
installAccountMenu()

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

      // An open account menu takes Escape itself, before any section behind it.
      // Otherwise Escape closes the last open section a person can see, inside the open
      // window when one is open; a window with none open inside closes itself.
      if (event.key === "Escape" && !shell.querySelector(":popover-open")) {
        const layer = [...shell.querySelectorAll<HTMLDialogElement>("dialog:modal")].at(-1) ?? shell
        const openDetails = [...layer.querySelectorAll<HTMLDetailsElement>("details[open]")]
          .filter(details => details.checkVisibility())
          .at(-1)

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

    // LiveView records a new address only once its page is drawn, so what a
    // #fragment names is reached here, after the page has started at its top.
    const onNavigate = () => {
      const named = hashTarget()
      if (named) arriveAt(named)
    }

    // The sidebar stands beside the page rather than in it, so a scroll over a
    // sidebar with no more of its own to scroll that way moves the page, down
    // to its footer. The open phone menu keeps its scroll to itself.
    const onWheel = (event: WheelEvent) => {
      const target = event.target instanceof Element ? event.target : null
      const overSidebar = target?.closest<HTMLElement>("#shell-sidebar")
      if (!overSidebar || event.ctrlKey || shell.dataset.menuOpen === "true") return
      const {scrollTop, scrollHeight, clientHeight} = overSidebar
      const room = event.deltaY > 0 ? scrollHeight - clientHeight - scrollTop : scrollTop
      if (room > 1) return
      const lines = event.deltaMode === WheelEvent.DOM_DELTA_LINE
      scroller()?.scrollBy({top: lines ? event.deltaY * 16 : event.deltaY})
    }

    shell.addEventListener("click", onClick)
    shell.addEventListener("keydown", onKeydown)
    shell.addEventListener("wheel", onWheel, {passive: true})
    window.addEventListener("popstate", onHistoryNavigation)
    window.addEventListener("phx:navigate", onNavigate)
    this.restoreState()
    // A page opened at a #fragment starts at what it names, otherwise at its top.
    const opened = hashTarget()
    if (opened) arriveAt(opened)
    else scroller()?.scrollTo({top: 0})
    shell.dataset.behaviorReady = "true"

    this.cleanup = () => {
      closeMenu(false)
      shell.removeEventListener("click", onClick)
      shell.removeEventListener("keydown", onKeydown)
      shell.removeEventListener("wheel", onWheel)
      window.removeEventListener("popstate", onHistoryNavigation)
      window.removeEventListener("phx:navigate", onNavigate)
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
  AtlasBlocks,
  AtlasField,
  AtlasHeat,
  AtlasRiver,
  Countdown,
  FleetTabs,
  FleetPreview,
  HarbourSea,
  HexField,
  HolographicCard,
  KeyCards,
  KeyCardTurn,
  KeyMap,
  LocalTime,
  MenuAgents,
  ModalDialog,
  MotionCascade,
  MotionCount,
  MotionList,
  MotionRefusal,
  MotionStamp,
  MotionTabs,
  MotionTick,
  NextKeyCard,
  OnchainSteps,
  PlacesChart,
  ScrollRow,
  ShellBehavior: composeHooks(shellBehavior, ShellViews),
  ThemeSwitch,
  TokenMenu,
  TreeCanvas,
  ValueCard,
  VerifiedConnections,
  Worldline,
}
if (!browserCsrfToken()) throw new Error("Missing CSRF token")

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
installAgentMessage()
installPageProgress()
installVitals()
installLaunchSteps()
watchPresses(document)
mountMotion(document)
window.liveSocket = liveSocket
