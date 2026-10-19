import {createCanvasIsland, type CanvasIslandController, type LoadRenderer} from "../canvas_island"
import type {HarbourLook, HarbourRenderer} from "../harbour/renderer"
import type {Agent, LayoutName, Place} from "../harbour/sim"
import {SLOW} from "./motion/shared"

/** The harbour the server named in `data-harbour-layout`. */
const browserLoadHarbour = (layout: LayoutName): LoadRenderer<HarbourRenderer> => async (canvas, size, onDeviceLost) => {
  const {createHarbourRenderer} = await import("../harbour/renderer")
  return createHarbourRenderer(canvas, size, onDeviceLost, layout)
}

/** The browser is saving data, by its own setting or the system's. */
const savingData = () =>
  matchMedia("(prefers-reduced-data: reduce)").matches ||
  (navigator as Navigator & {connection?: {saveData: boolean}}).connection?.saveData === true

/** One agent as the server wrote it, with the name its ship shows under the mouse. */
type CrewMember = Agent & {readonly name: string}

/** The agents as the server wrote them: who, the place of their last action, and their colour. */
const crewOf = (root: HTMLElement): CrewMember[] => JSON.parse(root.dataset.harbourCrew!) as CrewMember[]

/** The three buildings as the server wrote them in `data-harbour-places`: the name each shows under the mouse and the page it opens. */
type Places = Readonly<Record<Place, {readonly name: string; readonly href: string}>>

const placesOf = (root: HTMLElement): Places => JSON.parse(root.dataset.harbourPlaces!) as Places

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

/** Page parts a press is meant for, even where they let the sea show through. */
const PAGE_CONTROLS = "a, button, input, select, textarea, label, summary, img, svg, video, [role]"

/** A background colour, as the browser computes it, that paints nothing. */
const seeThrough = (colour: string) => colour === "transparent" || /^rgba\(.*,\s*0\)$|\/\s*0\)$/.test(colour)

/**
 * Whether the sea shows at the element under the pointer: it and everything
 * around it up to the page let the sea through, and it is neither a control
 * nor words of its own.
 */
export const onOpenSea = (element: Element) => {
  if (element.closest(PAGE_CONTROLS)) return false
  if ([...element.childNodes].some(node => node.nodeType === Node.TEXT_NODE && node.textContent!.trim() !== "")) return false
  for (let at: Element | null = element; at && at !== document.documentElement; at = at.parentElement) {
    const style = getComputedStyle(at)
    if (!seeThrough(style.backgroundColor) || style.backgroundImage !== "none") return false
  }
  return true
}

type HarbourSeaController = CanvasIslandController & {
  /** Hands the crew the server wrote last to the sea on screen. */
  sync(): void
}

type SeaPresses = {
  /** Pressing a ship hands its agent here. */
  open(agentId: string): void
  /** The buildings and how to open one: the backdrop's sea has them, a homepage section's has none. */
  places?: {readonly marks: Places; go(href: string): void}
}

/**
 * A sea of the harbour `data-harbour-layout` names: one ship for each recent
 * agent, sailing to the island of its last action and circling it.
 *
 * The sea always moves, so it draws every frame while the tab is showing. A
 * visitor who asked for less motion gets one still picture, redrawn only when an
 * agent moves on or the theme changes, and so does a browser saving data or a
 * device that can't give the sea its frames, such as a phone saving power,
 * until the tab is shown again.
 * Without WebGPU nothing is drawn and the page's own ground shows.
 *
 * Where the sea takes presses, a mouse over a ship shows its agent's name,
 * pressing a ship hands its agent to `open`, pressing the open sea starts a
 * ripple, and pressing an island does nothing. A sea with `places` names and
 * raises a building under the mouse and opens its page when pressed, there and
 * wherever the sea shows between the page's parts.
 */
const createHarbourSeaController = (root: HTMLElement, presses: SeaPresses): HarbourSeaController => {
  let sync = () => {}

  const island = createCanvasIsland<HarbourRenderer>(root, {}, {
    canvasSelector: "[data-harbour-canvas]",
    readyFlag: "harbourReady",
    browserLoad: browserLoadHarbour(root.dataset.harbourLayout as LayoutName),
    motionSensitive: false,
    continuous: true,
    interact({renderer, nudge, onReady, onStrain}) {
      const calm = window.matchMedia("(prefers-reduced-motion: reduce)")
      const light = window.matchMedia("(prefers-color-scheme: light)")
      const saving = savingData()
      let strained = false
      const holding = () => calm.matches || saving || strained
      const restyle = () => {
        renderer()?.setLook(lookOf(root, light))
        nudge()
      }
      const onCalmChange = () => {
        renderer()?.setCalm(holding())
        nudge()
      }
      const themeObserver = new MutationObserver(restyle)
      const stage = root.querySelector<HTMLElement>("[data-harbour-stage]")!
      const canvas = root.querySelector<HTMLCanvasElement>("[data-harbour-canvas]")!
      const tag = root.querySelector<HTMLElement>("[data-harbour-tag]")!
      const {open, places} = presses
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
        document.documentElement.classList.remove("harbour-pointing")
        renderer()?.lift(null)
      }
      /** The building under a point, if this sea has buildings to open. */
      const placeAt = (u: number, v: number): Place | null => (places ? (renderer()?.placeAt(u, v) ?? null) : null)
      /** Names the building at the pointer and raises it. */
      const showPlace = (place: Place, u: number, v: number) => {
        tag.textContent = places!.marks[place].name
        tag.dataset.kind = "place"
        renderer()!.lift(place)
        standAt(u, v)
      }
      const goTo = (place: Place) => {
        hideTag()
        places!.go(places!.marks[place].href)
      }

      const onPointerMove = (event: PointerEvent) => {
        if (event.pointerType !== "mouse") return
        const [u, v] = pointOf(event)
        const ship = renderer()?.shipAt(u, v)
        if (ship) {
          const agent = crew.find(member => member.id === ship.id)!
          tag.textContent = agent.name
          tag.dataset.kind = "ship"
          tag.style.setProperty("--sail", agent.color)
          canvas.style.cursor = "pointer"
          renderer()!.lift(null)
          return standAt(ship.u, ship.v)
        }
        const place = placeAt(u, v)
        if (!place) return hideTag()
        canvas.style.cursor = "pointer"
        showPlace(place, u, v)
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
        const place = placeAt(u, v)
        if (place) return goTo(place)
        if (!harbour.placeAt(u, v)) harbour.ripple(u, v)
      }
      // While the page lies over the sea, the sea takes no presses itself; the
      // page's open margins answer for the buildings under them.
      const throughPage = (event: MouseEvent) => {
        const at = event.target
        return at instanceof Element && !stage.contains(at) && onOpenSea(at)
      }
      const onPagePointerMove = (event: PointerEvent) => {
        if (event.pointerType !== "mouse" || stage.contains(event.target as Node)) return
        const [u, v] = pointOf(event)
        const place = throughPage(event) ? placeAt(u, v) : null
        if (!place) return hideTag()
        document.documentElement.classList.add("harbour-pointing")
        showPlace(place, u, v)
      }
      const onPageClick = (event: MouseEvent) => {
        if (!throughPage(event)) return
        const place = placeAt(...pointOf(event))
        if (place) goTo(place)
      }

      // The sea fades out and comes back as the still picture, rather than
      // stopping mid-wave. Given another chance, it moves on from there.
      onStrain(held => {
        strained = held
        if (!held) return onCalmChange()
        void canvas.animate({opacity: [1, 0]}, {duration: SLOW, easing: "ease-in"}).finished.then(() => {
          onCalmChange()
          canvas.animate({opacity: [0, 1]}, {duration: SLOW, easing: "ease-out"})
        })
      })
      onReady(() => {
        const harbour = renderer()!
        harbour.setCalm(holding())
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
      if (places) {
        document.addEventListener("pointermove", onPagePointerMove)
        document.addEventListener("click", onPageClick)
        document.documentElement.addEventListener("pointerleave", hideTag)
      }

      return () => {
        sync = () => {}
        themeObserver.disconnect()
        light.removeEventListener("change", restyle)
        calm.removeEventListener("change", onCalmChange)
        hideTag()
        stage.removeEventListener("pointermove", onPointerMove)
        stage.removeEventListener("pointerleave", hideTag)
        canvas.removeEventListener("click", onClick)
        document.removeEventListener("pointermove", onPagePointerMove)
        document.removeEventListener("click", onPageClick)
        document.documentElement.removeEventListener("pointerleave", hideTag)
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
  liveSocket: {js(): {exec(el: HTMLElement, encodedJS: string): void; navigate(href: string): void}}
}

/**
 * The backdrop's hook: the sea behind every page of the app, which takes no
 * presses until the page is lifted away (pages/harbour.css), apart from its
 * buildings where the sea shows between the page's parts. The sea lives in a
 * sticky LiveView that never sees the page's params, so it tells the backdrop
 * which page is on screen, on mount and after every live navigation.
 *
 * A new page, the card's link to a Key and a building's page included, brings
 * the page back down if it was lifted and closes the card, so nobody is left on
 * a page they can't see. The lift button's own commands bring it down, so its
 * pressed state and label follow.
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
    this.controller = createHarbourSeaController(this.el, {
      open: id => this.pushEvent("show_agent", {id}),
      places: {marks: placesOf(this.el), go: href => this.liveSocket.js().navigate(href)},
    })
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
    this.controller = createHarbourSeaController(this.el, {open: id => this.pushEvent("open_ship", {id})})
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
