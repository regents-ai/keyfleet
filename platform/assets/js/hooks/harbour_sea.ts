import {createCanvasIsland, type CanvasIslandController, type LoadRenderer} from "../canvas_island"
import type {HarbourLook, HarbourRenderer} from "../harbour/renderer"
import type {Agent, LayoutName} from "../harbour/sim"

/** The harbour the server named in `data-harbour-layout`. */
const browserLoadHarbour = (layout: LayoutName): LoadRenderer<HarbourRenderer> => async (canvas, size, onDeviceLost) => {
  const {createHarbourRenderer} = await import("../harbour/renderer")
  return createHarbourRenderer(canvas, size, onDeviceLost, layout)
}

/** One agent as the server wrote it, with the name its ship shows under the mouse. */
type CrewMember = Agent & {readonly name: string}

/** The agents as the server wrote them: who, the place of their last action, and their colour. */
const crewOf = (root: HTMLElement): CrewMember[] => JSON.parse(root.dataset.harbourCrew!) as CrewMember[]

/** Space kept between a ship's name and the sides of the screen, in pixels. */
const TAG_MARGIN = 4

/** Dark unless the page or the device asks for light, the same reading as the theme switch. */
const lookOf = (root: HTMLElement, light: MediaQueryList): HarbourLook => {
  const theme = document.documentElement.dataset.theme
  return {
    night: theme ? theme === "dark" : !light.matches,
    haze: getComputedStyle(root).getPropertyValue("--harbour-haze").trim(),
  }
}

type HarbourSeaController = CanvasIslandController & {
  /** Hands the crew the server wrote last to the sea on screen. */
  sync(): void
}

/**
 * A sea of the harbour `data-harbour-layout` names: one ship for each recent
 * agent, sailing to the island of its last action and circling it.
 *
 * The sea always moves, so it draws every frame while the tab is showing. A
 * visitor who asked for less motion gets one still picture, redrawn only when an
 * agent moves on or the theme changes. Without WebGPU nothing is drawn and the
 * page's own ground shows.
 *
 * Where the sea takes presses, a mouse over a ship shows its agent's name,
 * pressing a ship hands its agent to `open`, pressing the open sea starts a
 * ripple, and pressing an island does nothing.
 */
const createHarbourSeaController = (root: HTMLElement, open: (agentId: string) => void): HarbourSeaController => {
  let sync = () => {}

  const island = createCanvasIsland<HarbourRenderer>(root, {}, {
    canvasSelector: "[data-harbour-canvas]",
    readyFlag: "harbourReady",
    browserLoad: browserLoadHarbour(root.dataset.harbourLayout as LayoutName),
    motionSensitive: false,
    continuous: true,
    interact({renderer, nudge, onReady}) {
      const calm = window.matchMedia("(prefers-reduced-motion: reduce)")
      const light = window.matchMedia("(prefers-color-scheme: light)")
      const restyle = () => {
        renderer()?.setLook(lookOf(root, light))
        nudge()
      }
      const onCalmChange = () => {
        renderer()?.setCalm(calm.matches)
        nudge()
      }
      const themeObserver = new MutationObserver(restyle)
      const stage = root.querySelector<HTMLElement>("[data-harbour-stage]")!
      const canvas = root.querySelector<HTMLCanvasElement>("[data-harbour-canvas]")!
      const tag = root.querySelector<HTMLElement>("[data-harbour-tag]")!
      let crew = crewOf(root)

      const pointOf = (event: MouseEvent): [number, number] => {
        const box = canvas.getBoundingClientRect()
        return [(event.clientX - box.left) / box.width, (event.clientY - box.top) / box.height]
      }
      /** Stands the name on a point of the canvas, kept on the screen. */
      const standAt = (u: number, v: number) => {
        tag.hidden = false
        const box = root.getBoundingClientRect()
        const half = tag.offsetWidth / 2
        const x = Math.min(Math.max(u * box.width, half + TAG_MARGIN), box.width - half - TAG_MARGIN)
        const y = Math.max(v * box.height, tag.offsetHeight + TAG_MARGIN * 2)
        tag.style.translate = `${x}px ${y}px`
      }
      const hideTag = () => {
        tag.hidden = true
        canvas.style.cursor = ""
      }
      const onPointerMove = (event: PointerEvent) => {
        if (event.pointerType !== "mouse") return
        const ship = renderer()?.shipAt(...pointOf(event))
        if (!ship) return hideTag()
        const agent = crew.find(member => member.id === ship.id)!
        tag.textContent = agent.name
        tag.style.setProperty("--sail", agent.color)
        canvas.style.cursor = "pointer"
        standAt(ship.u, ship.v)
      }
      const onClick = (event: MouseEvent) => {
        const harbour = renderer()
        if (!harbour) return
        const [u, v] = pointOf(event)
        const ship = harbour.shipAt(u, v)
        if (ship) {
          hideTag()
          return open(ship.id)
        }
        if (!harbour.onIsland(u, v)) harbour.ripple(u, v)
      }
      onReady(() => {
        const harbour = renderer()!
        harbour.setCalm(calm.matches)
        harbour.setLook(lookOf(root, light))
        harbour.setAgents(crew)
      })
      sync = () => {
        crew = crewOf(root)
        renderer()?.setAgents(crew)
        nudge()
      }
      themeObserver.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]})
      light.addEventListener("change", restyle)
      calm.addEventListener("change", onCalmChange)
      stage.addEventListener("pointermove", onPointerMove)
      stage.addEventListener("pointerleave", hideTag)
      canvas.addEventListener("click", onClick)

      return () => {
        sync = () => {}
        themeObserver.disconnect()
        light.removeEventListener("change", restyle)
        calm.removeEventListener("change", onCalmChange)
        hideTag()
        stage.removeEventListener("pointermove", onPointerMove)
        stage.removeEventListener("pointerleave", hideTag)
        canvas.removeEventListener("click", onClick)
      }
    },
  })

  return {...island, sync: () => sync()}
}

type HarbourSeaHook = {
  el: HTMLElement
  controller?: HarbourSeaController
  shownPath?: string
  shownPage?: string
  onPageLoaded?: () => void
  pushEvent(event: string, payload: object): void
  liveSocket: {js(): {exec(el: HTMLElement, encodedJS: string): void}}
}

/**
 * The backdrop's hook: the sea behind every page of the app, which takes no
 * presses until the page is lifted away (pages/harbour.css). The sea lives in
 * a sticky LiveView that never sees the page's params, so it tells the
 * backdrop which page is on screen, on mount and after every live navigation,
 * and the backdrop picks the crew for it.
 *
 * A new page, the card's link to a Key included, brings the page back down if
 * it was lifted and closes the card, so nobody is left on a page they can't see.
 * The lift button's own commands bring it down, so its pressed state and label
 * follow.
 */
export const HarbourSea = {
  mounted(this: HarbourSeaHook) {
    this.onPageLoaded = () => {
      const page = window.location.pathname + window.location.search
      if (this.shownPage !== undefined && page !== this.shownPage) {
        const lift = document.getElementById("sea-lift")
        if (lift && document.body.classList.contains("sea-lifted"))
          this.liveSocket.js().exec(lift, lift.getAttribute("phx-click")!)
        if (document.getElementById("harbour-agent")) this.pushEvent("close_agent", {})
      }
      this.shownPage = page
      const path = window.location.pathname
      if (path === this.shownPath) return
      this.shownPath = path
      this.pushEvent("show_page", {path})
    }
    window.addEventListener("phx:page-loading-stop", this.onPageLoaded)
    this.onPageLoaded()
    this.controller = createHarbourSeaController(this.el, id => this.pushEvent("show_agent", {id}))
    this.controller.mount()
  },
  updated(this: HarbourSeaHook) {
    this.controller?.sync()
  },
  disconnected(this: HarbourSeaHook) {
    this.controller?.pause()
  },
  // A rejoin is a new backdrop process that knows nothing of the page yet.
  reconnected(this: HarbourSeaHook) {
    this.shownPath = undefined
    this.onPageLoaded?.()
    this.controller?.resume()
  },
  destroyed(this: HarbourSeaHook) {
    window.removeEventListener("phx:page-loading-stop", this.onPageLoaded!)
    this.controller?.destroy()
    this.controller = undefined
  },
}

type FleetSeaHook = {
  el: HTMLElement
  controller?: HarbourSeaController
  pushEvent(event: string, payload: object): void
}

/**
 * A fleet's sea in its section of the homepage, its ships that fleet's Keys.
 * Pressing a ship asks the page to open that Key's profile on the fleet's page.
 */
export const FleetSea = {
  mounted(this: FleetSeaHook) {
    this.controller = createHarbourSeaController(this.el, id => this.pushEvent("open_ship", {id}))
    this.controller.mount()
  },
  updated(this: FleetSeaHook) {
    this.controller?.sync()
  },
  disconnected(this: FleetSeaHook) {
    this.controller?.pause()
  },
  reconnected(this: FleetSeaHook) {
    this.controller?.resume()
  },
  destroyed(this: FleetSeaHook) {
    this.controller?.destroy()
    this.controller = undefined
  },
}
