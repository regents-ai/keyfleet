/**
 * The workspace's graph: pointing at an item, in the picture or in the list
 * under it, lights it, its links and the items at their other ends. The page
 * drew everything, links included, so this only marks what is lit and, on a
 * screen with WebGPU, draws the links again on the GPU with a glow that
 * eases in. Pressing an item is an ordinary link to its page.
 */
import {createCanvasIsland, type CanvasIslandController} from "../canvas_island"
import type {GraphRenderer, Link} from "../workspace_graph/renderer"
import {tone, watchTheme} from "../theme_tone"

type Island = {renderer(): GraphRenderer | undefined; nudge(): void}

type GraphHook = {
  el: HTMLElement
  controller?: CanvasIslandController
  island?: Island
  events?: AbortController
  lit?: string
}

const edges = (root: HTMLElement) => [...root.querySelectorAll<SVGPathElement>("[data-edge]")]

const links = (root: HTMLElement): Link[] =>
  edges(root).map(edge => ({
    points: (edge.dataset.curve ?? "").split(" ").map(Number),
    against: edge.dataset.type === "contradicts",
    dashed: ["forks", "reviews", "contradicts"].includes(edge.dataset.type ?? ""),
  }))

// The item a pointer or focus is on: a node of the picture or a row of the list.
const itemAt = (target: EventTarget | null) => {
  if (!(target instanceof Element)) return undefined
  const item = target.closest<HTMLElement | SVGElement>("[data-node], [data-row]")
  return item?.dataset.node ?? item?.dataset.row
}

// Marks the item lit, its links and the items they reach, and answers which
// links those are, by their place among the page's links.
const mark = (root: HTMLElement, lit: string | undefined): Set<number> => {
  const on = new Set<number>()
  const near = new Set<string>()
  edges(root).forEach((edge, i) => {
    const touches = lit !== undefined && (edge.dataset.source === lit || edge.dataset.target === lit)
    edge.toggleAttribute("data-lit", touches)
    if (!touches) return
    on.add(i)
    near.add(edge.dataset.source ?? "")
    near.add(edge.dataset.target ?? "")
  })
  for (const item of root.querySelectorAll<HTMLElement | SVGElement>("[data-node], [data-row]")) {
    const id = item.dataset.node ?? item.dataset.row ?? ""
    item.toggleAttribute("data-lit", id === lit)
    item.toggleAttribute("data-near", id !== lit && near.has(id))
  }
  root.toggleAttribute("data-lighting", lit !== undefined)
  return on
}

function relight(hook: GraphHook) {
  const on = mark(hook.el, hook.lit)
  hook.island?.renderer()?.light(on)
  hook.island?.nudge()
}

function redraw(hook: GraphHook) {
  hook.island?.renderer()?.links(links(hook.el))
  relight(hook)
}

// The GPU picture stands behind the drawn one, for as long as there is a
// picture to stand behind.
function start(hook: GraphHook) {
  const root = hook.el
  hook.controller = createCanvasIsland<GraphRenderer>(root, {}, {
    canvasSelector: "[data-graph-canvas]",
    readyFlag: "graphReady",
    motionSensitive: true,
    continuous: false,
    browserLoad: async (canvas, size, lost) => {
      const {createGraphRenderer} = await import("../workspace_graph/renderer")
      return createGraphRenderer(canvas, size, lost)
    },
    interact: ({renderer, nudge, onReady}) => {
      hook.island = {renderer, nudge}
      const retone = () => {
        renderer()?.tones(
          tone(root, "--color-fg-muted"),
          0.55,
          tone(root, "--ash-accent"),
          tone(root, "--color-error"),
        )
        nudge()
      }
      onReady(() => {
        retone()
        redraw(hook)
      })
      const forget = watchTheme(retone)
      return () => {
        forget()
        hook.island = undefined
      }
    },
  })
  hook.controller.mount()
}

function stop(hook: GraphHook) {
  hook.controller?.destroy()
  hook.controller = undefined
}

export const WorkspaceGraph = {
  mounted(this: GraphHook) {
    const root = this.el
    const point = (id: string | undefined) => {
      if (id === this.lit) return
      this.lit = id
      relight(this)
    }
    this.events = new AbortController()
    const options = {signal: this.events.signal, passive: true}
    root.addEventListener("pointerover", event => point(itemAt(event.target)), options)
    root.addEventListener("pointerleave", () => point(undefined), options)
    root.addEventListener("focusin", event => point(itemAt(event.target)), options)
    root.addEventListener(
      "focusout",
      event => {
        if (!root.contains(event.relatedTarget as Node | null)) point(undefined)
      },
      options,
    )
    if (root.querySelector("[data-graph-canvas]")) start(this)
  },
  // A new read of the workspace may move, add or take away items and links,
  // or leave none to draw.
  updated(this: GraphHook) {
    const drawn = this.el.querySelector("[data-graph-canvas]") !== null
    if (drawn && !this.controller) start(this)
    if (!drawn && this.controller) stop(this)
    redraw(this)
  },
  disconnected(this: GraphHook) {
    this.controller?.pause()
  },
  reconnected(this: GraphHook) {
    this.controller?.resume()
  },
  destroyed(this: GraphHook) {
    this.events?.abort()
    stop(this)
  },
}
