import {animate, createScope, utils} from "animejs"

import {createCanvasIsland, type CanvasIslandController, type LoadRenderer} from "../canvas_island"
import type {Place} from "../swarm_city/city"
import type {Theme} from "../swarm_city/looks"
import type {CityView, SwarmCityRenderer} from "../swarm_city/renderer"
import type {Agent} from "../swarm_city/swarm"
import {SLOW} from "./motion/shared"

/** The browser is saving data, by its own setting or the system's. */
const savingData = () =>
  matchMedia("(prefers-reduced-data: reduce)").matches ||
  (navigator as Navigator & {connection?: {saveData: boolean}}).connection?.saveData === true

/** One agent as the server wrote it, with the name its disc shows under the mouse. */
type CrewMember = Agent & {readonly name: string}

/** The agents as the server wrote them: who, the place of their last action, and their colour. */
const crewOf = (root: HTMLElement): CrewMember[] => JSON.parse(root.dataset.harbourCrew!) as CrewMember[]

/** The page's theme, which the server always writes on the page. */
const themeOf = (): Theme => document.documentElement.dataset.theme as Theme

const PLACES: readonly Place[] = ["castle", "forge", "inn"]

/** The whole city, seen from above its southern edge. */
const OVERVIEW = {x: 0, y: 2.2, z: 0.4, yaw: 0.65, pitch: 0.62, distance: 36}

/** Space kept between a disc's name and the sides of the picture, in pixels. */
const TAG_MARGIN = 4
/** How far a press may travel and still count as a press, not a drag, in pixels. */
const DRAG_SLOP = 5
/** How far one drag across the whole picture turns the city, and tips it, in radians. */
const TURN_ACROSS = Math.PI
const TIP_DOWN = 1.2
/** The camera never looks up from under the roofs or straight down on them. */
const LOWEST = 0.12
const HIGHEST = 1.15
/** How long a district takes to light, in milliseconds. */
const LIGHT = 320

const clamp = (value: number, low: number, high: number) => Math.min(high, Math.max(low, value))

type HarbourSeaController = CanvasIslandController & {
  /** Hands the crew the server wrote last to the city on screen. */
  sync(): void
}

/**
 * The swarm city: a dense city of thin outlined towers with three downtowns,
 * and one disc for each recent agent, flying to the district of its last
 * action and circling its towers, in the page's theme.
 *
 * The city always moves, so it draws every frame while the tab is showing. A
 * visitor who asked for less motion gets one still picture, redrawn only when
 * an agent moves on, the theme changes or a drag turns it, and so does a
 * browser saving data or a device that can't give the city its frames, such
 * as a phone saving power, until the tab is shown again.
 * Without WebGPU nothing is drawn and the page's own ground shows.
 *
 * Where the city takes presses, a drag turns it, a mouse over a disc shows its
 * agent's name, a mouse over a district lights it, and pressing a disc hands
 * its agent to `open`. Anime.js eases the districts' light and a released
 * drag; the renderer reads both when it draws.
 */
const createHarbourSeaController = (root: HTMLElement, open: (agentId: string) => void): HarbourSeaController => {
  const view: CityView = {...OVERVIEW, castle: 0, forge: 0, inn: 0}
  const scope = createScope({root})
  let sync = () => {}

  const browserLoad: LoadRenderer<SwarmCityRenderer> = async (canvas, size, onDeviceLost) => {
    const {createSwarmCityRenderer} = await import("../swarm_city/renderer")
    return createSwarmCityRenderer(canvas, size, onDeviceLost, view, themeOf())
  }

  const island = createCanvasIsland<SwarmCityRenderer>(root, {}, {
    canvasSelector: "[data-harbour-canvas]",
    readyFlag: "harbourReady",
    browserLoad,
    motionSensitive: false,
    continuous: true,
    interact({renderer, nudge, onReady, onStrain}) {
      const calm = window.matchMedia("(prefers-reduced-motion: reduce)")
      const saving = savingData()
      let strained = false
      const holding = () => calm.matches || saving || strained
      const stage = root.querySelector<HTMLElement>("[data-harbour-stage]")!
      const canvas = root.querySelector<HTMLCanvasElement>("[data-harbour-canvas]")!
      const tag = root.querySelector<HTMLElement>("[data-harbour-tag]")!
      let crew = crewOf(root)
      let theme = themeOf()
      let hovered: Place | null = null

      scope.add("light", () => {
        for (const place of PLACES) {
          const level = place === hovered ? 1 : 0
          if (view[place] === level) continue
          if (holding()) view[place] = level
          else animate(view, {[place]: level, duration: LIGHT, ease: "outQuad"})
        }
        if (holding()) nudge()
      })
      // A released drag carries on turning a little and comes to rest.
      scope.add("coast", (yaw: number, pitch: number) => {
        animate(view, {yaw, pitch, duration: 900, ease: "outCubic"})
      })

      const restyle = () => {
        const next = themeOf()
        if (next === theme) return
        theme = next
        void renderer()?.setTheme(theme).then(() => nudge())
      }
      const onCalmChange = () => {
        renderer()?.setCalm(holding())
        nudge()
      }
      const themeObserver = new MutationObserver(restyle)

      const pointOf = (event: MouseEvent): [number, number] => {
        const box = canvas.getBoundingClientRect()
        return [(event.clientX - box.left) / box.width, (event.clientY - box.top) / box.height]
      }
      /** Stands the name on a point of the canvas, kept inside the picture. */
      const standAt = (u: number, v: number) => {
        tag.hidden = false
        const box = root.getBoundingClientRect()
        const half = tag.offsetWidth / 2
        const x = Math.min(Math.max(u * box.width, half + TAG_MARGIN), box.width - half - TAG_MARGIN)
        const y = Math.max(v * box.height, tag.offsetHeight + TAG_MARGIN * 2)
        tag.style.translate = `${x}px ${y}px`
      }
      const hover = (place: Place | null) => {
        if (place === hovered) return
        hovered = place
        scope.methods.light!()
      }
      const hideTag = () => {
        tag.hidden = true
      }

      // A drag: where it started, the view it started from, and how fast it was turning when let go.
      let drag: {id: number; x: number; y: number; yaw: number; pitch: number; moved: boolean} | undefined
      let turning = {yaw: 0, pitch: 0, at: 0}
      let dragged = false

      const onPointerDown = (event: PointerEvent) => {
        if (!renderer() || event.button !== 0) return
        utils.remove(view, undefined, "yaw")
        utils.remove(view, undefined, "pitch")
        drag = {id: event.pointerId, x: event.clientX, y: event.clientY, yaw: view.yaw, pitch: view.pitch, moved: false}
        turning = {yaw: 0, pitch: 0, at: event.timeStamp}
        dragged = false
      }
      const onDrag = (event: PointerEvent) => {
        if (!drag || event.pointerId !== drag.id) return false
        const box = canvas.getBoundingClientRect()
        const dx = event.clientX - drag.x
        const dy = event.clientY - drag.y
        if (!drag.moved && Math.hypot(dx, dy) < DRAG_SLOP) return true
        if (!drag.moved) {
          drag.moved = true
          canvas.setPointerCapture(drag.id)
          hideTag()
          hover(null)
          stage.dataset.harbourDragging = ""
        }
        const yaw = drag.yaw - (dx / box.width) * TURN_ACROSS
        const pitch = clamp(drag.pitch + (dy / box.height) * TIP_DOWN, LOWEST, HIGHEST)
        const elapsed = Math.max(1, event.timeStamp - turning.at) / 1000
        turning = {yaw: (yaw - view.yaw) / elapsed, pitch: (pitch - view.pitch) / elapsed, at: event.timeStamp}
        view.yaw = yaw
        view.pitch = pitch
        if (holding()) nudge()
        return true
      }
      const onPointerUp = (event: PointerEvent) => {
        if (!drag || event.pointerId !== drag.id) return
        dragged = drag.moved
        drag = undefined
        delete stage.dataset.harbourDragging
        // A drag let go mid-swing carries on a little; one held still first stays put.
        if (!dragged || holding() || event.timeStamp - turning.at > 80) return
        scope.methods.coast!(view.yaw + turning.yaw * 0.25, clamp(view.pitch + turning.pitch * 0.25, LOWEST, HIGHEST))
      }
      const onPointerCancel = () => {
        drag = undefined
        delete stage.dataset.harbourDragging
      }
      const onPointerMove = (event: PointerEvent) => {
        const city = renderer()
        if (onDrag(event) || event.pointerType !== "mouse" || !city) return
        const [u, v] = pointOf(event)
        const node = city.nodeAt(u, v)
        canvas.style.cursor = node ? "pointer" : ""
        if (!node) {
          hideTag()
          return hover(city.districtAt(u, v)?.place ?? null)
        }
        const agent = crew.find(member => member.id === node.id)!
        tag.textContent = agent.name
        tag.style.setProperty("--sail", agent.color)
        standAt(node.u, node.v)
        hover(null)
      }
      const onPointerLeave = () => {
        if (drag?.moved) return
        hideTag()
        hover(null)
        canvas.style.cursor = ""
      }
      const onClick = (event: MouseEvent) => {
        const city = renderer()
        if (dragged || !city) {
          dragged = false
          return
        }
        const node = city.nodeAt(...pointOf(event))
        if (!node) return
        hideTag()
        open(node.id)
      }
      // The city fades out and comes back as the still picture, rather than
      // stopping mid-flight. Given another chance, it moves on from there.
      onStrain(held => {
        strained = held
        if (!held) return onCalmChange()
        void canvas.animate({opacity: [1, 0]}, {duration: SLOW, easing: "ease-in"}).finished.then(() => {
          onCalmChange()
          canvas.animate({opacity: [0, 1]}, {duration: SLOW, easing: "ease-out"})
        })
      })
      onReady(() => {
        const city = renderer()!
        city.setCalm(holding())
        city.setAgents(crew)
        // The theme may have changed while the city was loading.
        theme = themeOf()
        void city.setTheme(theme).then(() => nudge())
      })
      sync = () => {
        crew = crewOf(root)
        renderer()?.setAgents(crew)
        nudge()
      }
      themeObserver.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]})
      calm.addEventListener("change", onCalmChange)
      canvas.addEventListener("pointerdown", onPointerDown)
      stage.addEventListener("pointermove", onPointerMove)
      canvas.addEventListener("pointerup", onPointerUp)
      canvas.addEventListener("pointercancel", onPointerCancel)
      stage.addEventListener("pointerleave", onPointerLeave)
      canvas.addEventListener("click", onClick)

      return () => {
        sync = () => {}
        drag = undefined
        themeObserver.disconnect()
        calm.removeEventListener("change", onCalmChange)
        hideTag()
        canvas.removeEventListener("pointerdown", onPointerDown)
        stage.removeEventListener("pointermove", onPointerMove)
        canvas.removeEventListener("pointerup", onPointerUp)
        canvas.removeEventListener("pointercancel", onPointerCancel)
        stage.removeEventListener("pointerleave", onPointerLeave)
        canvas.removeEventListener("click", onClick)
      }
    },
  })

  return {
    ...island,
    sync: () => sync(),
    destroy() {
      scope.revert()
      island.destroy()
    },
  }
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
 * The backdrop's hook: the city behind every page of the app, which takes no
 * presses until the page is lifted away (pages/harbour.css). The city lives in
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
 * A fleet's city in its section of the homepage, its discs that fleet's Keys.
 * Pressing a disc asks the page to open that Key's profile on the fleet's page.
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
