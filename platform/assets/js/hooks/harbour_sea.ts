import {createCanvasIsland, type CanvasIslandController, type LoadRenderer} from "../canvas_island"
import type {HarbourLook, HarbourRenderer} from "../harbour/renderer"
import type {Agent} from "../harbour/sim"

const browserLoadHarbour: LoadRenderer<HarbourRenderer> = async (canvas, size, onDeviceLost) => {
  const {createHarbourRenderer} = await import("../harbour/renderer")
  return createHarbourRenderer(canvas, size, onDeviceLost)
}

/** One agent as the server wrote it, with the name its ship shows under the mouse. */
type CrewMember = Agent & {readonly name: string}

/** The agents as the server wrote them: who, the place of their last action, and their colour. */
const crewOf = (root: HTMLElement): CrewMember[] => JSON.parse(root.dataset.harbourCrew!) as CrewMember[]

/** Space kept between a ship's name and the sides of the screen, in pixels. */
const TAG_MARGIN = 4

/** Pixels in one line of a wheel that counts in lines. */
const WHEEL_LINE = 16

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
 * The sea behind every page of the app: one ship for each recent agent, sailing
 * to the island of its last action and circling it.
 *
 * The sea always moves, so it draws every frame while the tab is showing. A
 * visitor who asked for less motion gets one still picture, redrawn only when an
 * agent moves on or the theme changes. Without WebGPU nothing is drawn and the
 * page's own ground shows.
 *
 * A mouse over a ship shows its agent's name. Pressing a ship hands its agent to
 * `open`, pressing the open sea starts a ripple, and pressing an island does
 * nothing.
 */
const createHarbourSeaController = (root: HTMLElement, open: (agentId: string) => void): HarbourSeaController => {
  let sync = () => {}

  const island = createCanvasIsland<HarbourRenderer>(root, {}, {
    canvasSelector: "[data-harbour-canvas]",
    readyFlag: "harbourReady",
    browserLoad: browserLoadHarbour,
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
      // A mouse over the open margin is over the sea, not the page's scroller,
      // so its wheel is handed to the scroller while that can still move.
      const onWheel = (event: WheelEvent) => {
        const scroller = document.getElementById("app-shell-scroller")
        if (!scroller || document.body.classList.contains("sea-lifted")) return
        const scale = event.deltaMode === WheelEvent.DOM_DELTA_LINE ? WHEEL_LINE : 1
        const top = event.deltaY * scale
        const room = top < 0 ? scroller.scrollTop : scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop
        if (room < 1) return
        event.preventDefault()
        scroller.scrollBy({top, left: event.deltaX * scale})
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
      stage.addEventListener("wheel", onWheel, {passive: false})

      return () => {
        sync = () => {}
        themeObserver.disconnect()
        light.removeEventListener("change", restyle)
        calm.removeEventListener("change", onCalmChange)
        hideTag()
        stage.removeEventListener("pointermove", onPointerMove)
        stage.removeEventListener("pointerleave", hideTag)
        canvas.removeEventListener("click", onClick)
        stage.removeEventListener("wheel", onWheel)
      }
    },
  })

  return {...island, sync: () => sync()}
}

type HarbourSeaHook = {
  el: HTMLElement
  controller?: HarbourSeaController
  shownPath?: string
  onPageLoaded?: () => void
  pushEvent(event: string, payload: object): void
}

/**
 * The backdrop's hook. The sea lives in a sticky LiveView that never sees the
 * page's params, so it tells the backdrop which page is on screen, on mount and
 * after every live navigation, and the backdrop picks the crew for it.
 */
export const HarbourSea = {
  mounted(this: HarbourSeaHook) {
    this.onPageLoaded = () => {
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
