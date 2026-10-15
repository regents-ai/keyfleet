/**
 * The homepage's moving parts around "Buy Next Key": the hex field behind the
 * hero and the Club's map, and the turn of the next Key's card. Each
 * only presents; the page is complete and readable before any of it loads, and
 * none of it decides whether the button can be pressed.
 */
import {createAnimatable, createScope, type AnimatableObject, type Scope} from "animejs"
import {createCanvasIsland, type CanvasIslandController} from "../canvas_island"
import type {FieldRenderer, Rgb} from "../home_hero/renderer"
import {EASE_OUT, still} from "./motion/shared"

/** Any colour the page can state, as the three 0..1 sRGB channels a shader takes. */
let swatch: CanvasRenderingContext2D | undefined

const tone = (root: HTMLElement, property: string): Rgb => {
  swatch ??= document.createElement("canvas").getContext("2d", {willReadFrequently: true})!
  const probe = root.ownerDocument.createElement("span")
  probe.hidden = true
  probe.style.color = `var(${property})`
  root.append(probe)
  const color = getComputedStyle(probe).color
  probe.remove()
  swatch.clearRect(0, 0, 1, 1)
  swatch.fillStyle = color
  swatch.fillRect(0, 0, 1, 1)
  const [red = 0, green = 0, blue = 0] = swatch.getImageData(0, 0, 1, 1).data
  return [red / 255, green / 255, blue / 255]
}

/** Calls `retone` whenever the page's light or dark changes. */
const watchTheme = (retone: () => void) => {
  const scheme = matchMedia("(prefers-color-scheme: dark)")
  const observer = new MutationObserver(retone)
  observer.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]})
  scheme.addEventListener("change", retone)
  return () => {
    observer.disconnect()
    scheme.removeEventListener("change", retone)
  }
}

/** Where a pointer stands across an element's box, 0..1 on each axis and held inside it. */
const across = (event: PointerEvent, box: DOMRect): [number, number] => [
  Math.min(1, Math.max(0, (event.clientX - box.left) / box.width)),
  Math.min(1, Math.max(0, (event.clientY - box.top) / box.height)),
]

const finePointer = () => matchMedia("(hover: hover) and (pointer: fine)").matches

type IslandHook = {el: HTMLElement; controller?: CanvasIslandController}

/**
 * The hex field. `data-field-cell` is the distance between neighbouring tiles
 * in CSS pixels; `data-field-across` instead fits that many tiles across the
 * field, so it lies under a map drawn that many keys wide. The pointer anywhere
 * in the element marked `data-field-scope` lights the tiles near it; in the
 * hero, previewing the Key warms the tiles around its card. Less motion keeps
 * the picture and drops the pointer's light.
 */
export const HexField = {
  mounted(this: IslandHook) {
    const root = this.el
    const scope = root.closest<HTMLElement>("[data-field-scope]") ?? root
    const buy = scope.querySelector<HTMLElement>("[data-key-preview]")
    const card = buy?.querySelector<HTMLElement>("[data-key-card]")
    const {fieldAcross, fieldCell} = root.dataset

    this.controller = createCanvasIsland<FieldRenderer>(root, {}, {
      canvasSelector: "[data-field-canvas]",
      readyFlag: "fieldReady",
      motionSensitive: false,
      browserLoad: async (canvas, size, lost) => {
        const {createFieldRenderer} = await import("../home_hero/renderer")
        const cell = () => (fieldAcross ? canvas.clientWidth / Number(fieldAcross) : Number(fieldCell))
        return createFieldRenderer(canvas, size, lost, cell)
      },
      interact: ({canvas, renderer, nudge, onReady}) => {
        const retone = () => {
          renderer()?.tones(tone(root, "--rl-field-line"), tone(root, "--rl-field-light"))
          nudge()
        }
        // The Key's light is centred on the card wherever the layout has put it.
        const aim = () => {
          if (!card) return
          const field = canvas().getBoundingClientRect()
          const box = card.getBoundingClientRect()
          renderer()?.key(
            (box.left + box.width / 2 - field.left) / field.width,
            (box.top + box.height / 2 - field.top) / field.height,
            Math.max(box.width, box.height) * 0.95,
          )
        }
        let hovering = false
        let focused = false
        const preview = () => {
          aim()
          renderer()?.lit(hovering || focused)
          nudge()
        }
        onReady(() => {
          retone()
          preview()
        })

        const onMove = (event: PointerEvent) => {
          if (!event.isPrimary || still(root)) return
          const box = canvas().getBoundingClientRect()
          renderer()?.point((event.clientX - box.left) / box.width, (event.clientY - box.top) / box.height)
          nudge()
        }
        const onLeave = () => {
          renderer()?.rest()
          nudge()
        }
        const onEnter = () => {
          hovering = true
          preview()
        }
        const onExit = () => {
          hovering = false
          preview()
        }
        const onFocus = (event: FocusEvent) => {
          focused = (event.target as Element).matches(":focus-visible")
          preview()
        }
        const onBlur = () => {
          focused = false
          preview()
        }

        const events = new AbortController()
        const options = {signal: events.signal, passive: true}
        if (finePointer()) {
          scope.addEventListener("pointermove", onMove, options)
          scope.addEventListener("pointerleave", onLeave, options)
          buy?.addEventListener("pointerenter", onEnter, options)
          buy?.addEventListener("pointerleave", onExit, options)
        }
        buy?.addEventListener("focusin", onFocus, options)
        buy?.addEventListener("focusout", onBlur, options)
        const forget = watchTheme(retone)
        const resized = new ResizeObserver(preview)
        if (card) resized.observe(card)

        return () => {
          events.abort()
          forget()
          resized.disconnect()
        }
      },
    })
    this.controller.mount()
  },
  disconnected(this: IslandHook) {
    this.controller?.pause()
  },
  reconnected(this: IslandHook) {
    this.controller?.resume()
  },
  destroyed(this: IslandHook) {
    this.controller?.destroy()
    this.controller = undefined
  },
}

type KeyCardHook = {el: HTMLElement; scope?: Scope; release?: () => void}

/**
 * The next Key's card. Under a mouse, pointing at the card or its button turns
 * the card a little toward the pointer, and it settles when the pointer leaves.
 * A finger, a keyboard or less motion gets the card as it is.
 */
export const NextKeyCard = {
  mounted(this: KeyCardHook) {
    const root = this.el
    const area = root.closest<HTMLElement>("[data-key-preview]") ?? root
    const tilt = root.querySelector<HTMLElement>("[data-key-tilt]")!
    let turn: AnimatableObject | undefined

    const scope = createScope({root, mediaQueries: {reduced: "(prefers-reduced-motion: reduce)"}})
    this.scope = scope.add(() => {
      if (scope.matches.reduced || !finePointer()) return
      turn = createAnimatable(tilt, {rotateX: 0, rotateY: 0, duration: 420, ease: EASE_OUT})
      return () => {
        turn = undefined
      }
    })

    const onTurn = (event: PointerEvent) => {
      if (!turn || !event.isPrimary || still(root)) return
      const [x, y] = across(event, root.getBoundingClientRect())
      turn.rotateY((x - 0.5) * 9)
      turn.rotateX((0.5 - y) * 7)
    }
    const onSettle = () => {
      turn?.rotateX(0)
      turn?.rotateY(0)
    }
    const events = new AbortController()
    area.addEventListener("pointermove", onTurn, {signal: events.signal, passive: true})
    area.addEventListener("pointerleave", onSettle, {signal: events.signal, passive: true})
    this.release = () => events.abort()
  },
  destroyed(this: KeyCardHook) {
    this.release?.()
    this.scope?.revert()
  },
}
