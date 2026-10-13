import {
  createCanvasIsland,
  type CanvasIslandController,
  type CanvasIslandOptions,
  type LoadRenderer,
  type MediaQuery,
} from "../canvas_island"
import type {CrownRenderer} from "../crown"

export type CrownOptions = CanvasIslandOptions<CrownRenderer> & {
  pointerQuery?: () => MediaQuery
  viewportHeight?: () => number
}

export type CrownController = CanvasIslandController & {
  /**
   * Reads the crown's look again and hands it to the crown already on screen.
   * For a site whose look follows something the page can change, such as a theme.
   */
  restyle(): void
}

/** The look the markup names in `data-crown-look`, from this site's own looks. */
const lookFor = async (root: HTMLElement) => {
  const {crownLook} = await import("../crown_looks")
  return crownLook(root.dataset.crownLook!)
}

const browserLoadCrown =
  (root: HTMLElement): LoadRenderer<CrownRenderer> =>
  async (canvas, size, onDeviceLost) => {
    const [{createCrownRenderer}, look] = await Promise.all([import("../crown"), lookFor(root)])
    return createCrownRenderer(canvas, size, onDeviceLost, look)
  }

const clampUnit = (value: number): number => Math.min(1, Math.max(0, value))

/**
 * The glass crown: thirteen cubes and three beams, drawn on the island's canvas.
 *
 * The island is a layer behind the stage it decorates and takes no pointer
 * events itself, so the pointer is read from that stage: it turns the camera a
 * little, swings the beams and, in a look with quadrants, tints them by the
 * quarter of the stage it is over. A touch is not a hover, so on a phone the crown
 * takes its aim from how far the stage has travelled up the screen.
 *
 * A visitor who asked for less motion gets the crown as one composed shot: it is
 * drawn, and then left alone. Without WebGPU nothing is drawn, and the still
 * picture the server rendered stays.
 */
export const createCrownController = (
  root: HTMLElement,
  options: CrownOptions = {},
): CrownController => {
  const pointerQuery = options.pointerQuery ?? (() => window.matchMedia("(pointer: fine)"))
  const viewportHeight = options.viewportHeight ?? (() => window.innerHeight)
  const motionQuery =
    options.motionQuery ?? (() => window.matchMedia("(prefers-reduced-motion: reduce)"))
  let restyle = () => {}

  const island = createCanvasIsland(root, options, {
    canvasSelector: "[data-crown-canvas]",
    readyFlag: "crownReady",
    browserLoad: browserLoadCrown(root),
    motionSensitive: false,
    continuous: false,
    interact({root: layer, canvas, renderer, nudge, onReady}) {
      const stage = () => layer.parentElement!
      const onPointerMove = (event: PointerEvent) => {
        if (event.isPrimary === false) return
        const current = renderer()
        if (!current) return
        const {left, top, width, height} = stage().getBoundingClientRect()
        const x = (event.clientX - left) / width
        const y = (event.clientY - top) / height
        current.aim(x, y)
        current.point(x, y)
        nudge()
      }
      const onPointerLeave = () => {
        renderer()?.rest()
        nudge()
      }
      const onScroll = () => {
        const current = renderer()
        if (!current) return
        const {top, height} = canvas().getBoundingClientRect()
        const travel = viewportHeight() + height
        if (travel <= 0) return
        current.aim(0.5, clampUnit((viewportHeight() - top) / travel))
        nudge()
      }
      // A crown still on its way picks its look up when it lands, so only one
      // already drawn has anything to be handed.
      restyle = () => {
        if (!renderer()) return
        void lookFor(layer).then(look => {
          renderer()?.restyle(look)
          nudge()
        })
      }

      const fine = pointerQuery().matches
      const calm = motionQuery()
      const follow = () => {
        if (fine) {
          stage().addEventListener("pointermove", onPointerMove, {passive: true})
          stage().addEventListener("pointerleave", onPointerLeave, {passive: true})
        } else {
          document.addEventListener("scroll", onScroll, {passive: true})
        }
      }
      const unfollow = () => {
        stage().removeEventListener("pointermove", onPointerMove)
        stage().removeEventListener("pointerleave", onPointerLeave)
        document.removeEventListener("scroll", onScroll)
      }
      const onCalmChange = () => {
        unfollow()
        if (calm.matches) onPointerLeave()
        else follow()
      }

      if (!calm.matches) follow()
      calm.addEventListener("change", onCalmChange)
      // The visitor may arrive part-way down the page, so the first shot is
      // composed for where the stage already is.
      if (!fine) onReady(() => void (calm.matches || onScroll()))

      return () => {
        restyle = () => {}
        calm.removeEventListener("change", onCalmChange)
        unfollow()
      }
    },
  })

  return {...island, restyle: () => restyle()}
}

type CrownHook = {
  el: HTMLElement
  controller?: CrownController
}

export const Crown = {
  mounted(this: CrownHook) {
    this.controller = createCrownController(this.el)
    this.controller.mount()
  },
  disconnected(this: CrownHook) {
    this.controller?.pause()
  },
  reconnected(this: CrownHook) {
    this.controller?.resume()
  },
  destroyed(this: CrownHook) {
    this.controller?.destroy()
    this.controller = undefined
  },
}
