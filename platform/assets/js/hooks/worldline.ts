/**
 * A fleet's Worldline (`KeyfleetWeb.WorldlineLive`): its line runs through
 * time from left to right, the head at now, with the fleet's trails turning
 * around it and every event a mark on its trail (`../worldline/trails`).
 *
 * The page sends the newest events once it is live (`worldline:page`), older
 * ones as the reader pans back to them (the reply to `worldline_older`), and
 * new ones a moment after they happen (`worldline:heard`), which arrive at
 * the head. Drag pans through time and keeps going a little when let go; the
 * wheel or a pinch zooms; the arrow keys pan and plus and minus zoom. One
 * real link follows the mark pointed at, tapped or nearest the middle while
 * the picture has the keyboard, so it opens as any link does, in a new tab
 * too.
 *
 * The picture is drawn only with WebGPU. Without it the line and its head the
 * page drew stay, with a note that the List has every event. For a reader who
 * asked for less motion nothing orbits, reveals, glides or pulses; the
 * picture and its links still work.
 */
import {animate, type AnimationParams, type JSAnimation} from "animejs"

import {createCanvasIsland, type CanvasIslandController, type IslandRenderer} from "../canvas_island"
import type {Hook} from "../hook_composition"
import {showingTheme, watchTheme} from "../theme"
import {tone} from "../theme_tone"
import type {Tones, WorldlineRenderer} from "../worldline/renderer"
import {MAX_EVENTS, lay, nearest, pack, project, type Layout, type View, type WorldEvent} from "../worldline/trails"
import {localTime} from "./local_time"
import {BASE, EASE_OUT, FAST, play, still} from "./motion/shared"

type WorldlineHook = {
  el: HTMLElement
  pushEvent<Reply>(event: string, payload: unknown, onReply: (reply: Reply) => void): void
  handleEvent<Payload>(event: string, callback: (payload: Payload) => void): void
  controller?: CanvasIslandController
  cleanup?: () => void
}

type Page = {events: WorldEvent[]; older: boolean; now: number}
type Older = {events: WorldEvent[]; older: boolean}

type Island = IslandRenderer & {readonly gpu: WorldlineRenderer}

/** Where the head stands across the picture while it follows now. */
const HEAD_AT = 0.85
/** The narrowest and widest stretch of time the picture shows, in seconds. */
const MIN_SPAN = 120
const MAX_SPAN = 400 * 24 * 3600
/** How fast the trails orbit the line, in radians a second. */
const ORBIT = (2 * Math.PI) / 90
/** How near a mark must be to point at it, in CSS pixels, by mouse and by finger. */
const NEAR = 24
const NEAR_TOUCH = 36
/** How far a key press pans, of the width, and zooms. */
const KEY_PAN = 0.12
const KEY_ZOOM = 0.7
/** How fast a pan let go slows, in milliseconds to lose most of its speed. */
const GLIDE = 325
/** How far a press moves before it is a drag, in CSS pixels. */
const DRAG = 4

const reader = () => ({locale: undefined, timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone})

export const Worldline: Hook = {
  mounted(this: WorldlineHook) {
    const root = this.el
    const link = root.querySelector<HTMLAnchorElement>("[data-worldline-focus]")!
    const card = link.querySelector<HTMLElement>("[data-focus-card]")!
    const what = link.querySelector<HTMLElement>("[data-focus-what]")!
    const title = link.querySelector<HTMLElement>("[data-focus-title]")!
    const meta = link.querySelector<HTMLElement>("[data-focus-meta]")!
    if (!navigator.gpu) root.dataset.worldlineStill = "true"

    // The events on show and how they lay out, by the page's clock.
    const events = new Map<string, WorldEvent>()
    let layout: Layout = lay([], 0)
    let anchor = 0
    let skew = 0
    let older = false
    let asking = false
    let loaded = false
    let changed = false

    // Where the picture stands: how much time it shows, the time at its right
    // edge, and whether that edge follows now.
    let span = 24 * 3600
    let right = 0
    let following = true
    let width = 1
    let height = 1
    let orbit = 0
    let ticked: number | undefined
    let velocity = 0
    let strained = false

    // What anime.js moves: the reveal, the mark in focus, and an arrival.
    const motion = {revealed: 1e12, emphasis: 1, arrival: 0, arrivedFrom: 1e12}
    const running = new Set<JSAnimation>()
    let focus: number | undefined
    let focusBy: "pointer" | "key" | undefined

    let nudge = () => {}

    const now = () => (Date.now() + skew - anchor) / 1000
    const view = (): View => ({left: right - span, perPx: span / width, width, height})
    const oldest = () => layout.placed[0]?.t

    // One of anime.js's runs over `motion`, each frame of it drawn. A run
    // begun over another of the same value takes over from where it was.
    const run = (params: AnimationParams, finished = () => {}) => {
      const animation = animate(motion, {
        ...params,
        onUpdate: () => nudge(),
        onComplete: done => {
          running.delete(done)
          finished()
          nudge()
        },
      })
      running.add(animation)
    }

    const follow = () => {
      following = true
      right = now() + span * (1 - HEAD_AT)
    }

    // The picture never runs past now on the right, nor far into the empty
    // past on the left when nothing older is left to read.
    const hold = () => {
      span = Math.min(MAX_SPAN, Math.max(MIN_SPAN, span))
      const latest = now() + span * (1 - HEAD_AT)
      if (right >= latest) follow()
      const first = oldest()
      if (!older && first !== undefined && right - span < first - span * 0.9 && right < latest)
        right = Math.min(latest, first + span * 0.1)
    }

    const pan = (dx: number) => {
      right -= dx * (span / width)
      following = false
      hold()
    }

    // Zooms about a point of the picture, keeping the time under it in place;
    // while following, about the head.
    const zoom = (x: number, factor: number) => {
      if (following) {
        span *= factor
        hold()
        follow()
      } else {
        const at = right - span + x * (span / width)
        span = Math.min(MAX_SPAN, Math.max(MIN_SPAN, span * factor))
        right = at + (width - x) * (span / width)
        hold()
      }
    }

    // The whole history read so far fits, with the head where it follows now.
    const fit = () => {
      const first = oldest()
      span = first === undefined ? 24 * 3600 : Math.max(600, (now() - first) / (HEAD_AT - 0.04))
      follow()
      hold()
    }

    // The mark in focus stays the same event when others arrive around it.
    const relayout = () => {
      const kept = focus === undefined ? undefined : layout.placed[focus].event.id
      layout = lay([...events.values()], anchor)
      if (kept !== undefined) focus = layout.placed.findIndex(point => point.event.id === kept)
      changed = true
    }

    const when = (at: number) => localTime(new Date(at), new Date(Date.now() + skew), "stamp", reader())

    const showLink = (index: number) => {
      const event = layout.placed[index].event
      link.href = event.path
      if (event.live) {
        link.dataset.phxLink = "patch"
        link.dataset.phxLinkState = "push"
      } else {
        delete link.dataset.phxLink
        delete link.dataset.phxLinkState
      }
      what.textContent = event.what
      title.textContent = event.title
      meta.textContent = [event.who, when(event.at)].filter(Boolean).join(" · ")
    }

    const choose = (index: number | undefined, by: "pointer" | "key") => {
      if (index === focus) {
        if (index !== undefined) focusBy = by
        return
      }
      const appearing = focus === undefined && index !== undefined
      focus = index
      focusBy = index === undefined ? undefined : by
      if (index === undefined) {
        link.hidden = true
      } else {
        showLink(index)
        link.hidden = false
        if (appearing && !still(root)) play(card, {opacity: [0, 1], duration: FAST, ease: EASE_OUT})
      }
      if (still(root)) motion.emphasis = 1
      else run({emphasis: [0, 1], duration: BASE, ease: EASE_OUT})
      nudge()
    }

    // While the picture has the keyboard, the mark nearest its middle is the one shown.
    const chooseMiddle = () =>
      choose(nearest(layout.placed, view(), orbit, width / 2, height / 2, width), "key")

    // The link stands on the mark in focus, its words to whichever side has room.
    const placeLink = () => {
      if (focus === undefined) return
      const point = layout.placed[focus]
      const at = project(point.t, point.theta, point.shape, view(), orbit)
      link.style.transform = `translate(${at.x.toFixed(1)}px, ${at.y.toFixed(1)}px)`
      link.dataset.side = at.x > width - 232 ? "left" : "right"
      link.dataset.edge = at.y < 76 ? "below" : "above"
    }

    // Older events are read as the reader pans back to them, one page at a time.
    const readOlder = () => {
      const first = oldest()
      if (!older || asking || first === undefined || events.size >= MAX_EVENTS) return
      if (right - span > first + span * 0.15) return
      asking = true
      this.pushEvent<Older>("worldline_older", {}, reply => {
        asking = false
        older = reply.older
        for (const event of reply.events) events.set(event.id, event)
        relayout()
        nudge()
      })
    }

    const page = ({events: newest, older: more, now: serverNow}: Page) => {
      const first = !loaded
      loaded = true
      skew = serverNow - Date.now()
      anchor = serverNow
      older = more
      asking = false
      events.clear()
      for (const event of newest) events.set(event.id, event)
      choose(undefined, "pointer")
      relayout()
      fit()
      const start = oldest()
      if (first && start !== undefined && !still(root)) {
        motion.revealed = start
        run({revealed: [start, now()], duration: 1100, ease: EASE_OUT}, () => (motion.revealed = 1e12))
      }
      nudge()
    }

    const heard = ({events: arrived}: {events: WorldEvent[]}) => {
      const fresh = arrived.filter(event => !events.has(event.id))
      for (const event of arrived) events.set(event.id, event)
      relayout()
      if (fresh.length > 0 && !still(root)) {
        motion.arrivedFrom = Math.min(...fresh.map(event => (event.at - anchor) / 1000))
        run({arrival: [1, 0], duration: 1400, ease: EASE_OUT})
      }
      nudge()
    }

    this.handleEvent<Page>("worldline:page", page)
    this.handleEvent<{events: WorldEvent[]}>("worldline:heard", heard)

    // One frame: the orbit turns, a pan let go glides on, and the head
    // follows now. True while anything still moves.
    const advance = (time: number) => {
      const dt = ticked === undefined ? 0 : Math.min(50, time - ticked)
      ticked = time
      const moving = !still(root) && !strained
      if (moving) orbit = (orbit + (dt / 1000) * ORBIT) % (2 * Math.PI)
      if (velocity !== 0) {
        pan(velocity * dt)
        velocity *= Math.exp(-dt / GLIDE)
        if (Math.abs(velocity) < 0.01 || following) velocity = 0
      }
      if (following) follow()
      readOlder()
      return moving || velocity !== 0 || running.size > 0
    }

    const tones = (): Tones => {
      const dark = showingTheme() === "dark"
      return {
        line: tone(root, "--worldline-line"),
        workspace: tone(root, "--worldline-workspace"),
        code: tone(root, "--worldline-code"),
        notebooks: tone(root, "--worldline-notebooks"),
        chat: tone(root, "--worldline-chat"),
        opened: tone(root, "--worldline-opened"),
        closed: tone(root, "--worldline-closed"),
        poll: tone(root, "--worldline-polls"),
        glow: dark ? 0.34 : 0.14,
        far: dark ? 0.36 : 0.42,
      }
    }

    this.controller = createCanvasIsland<Island>(root, {}, {
      canvasSelector: "[data-worldline-canvas]",
      readyFlag: "worldlineReady",
      // The picture is the page's content, so it is drawn for every reader;
      // for one who asked for less motion it holds still.
      motionSensitive: false,
      continuous: true,
      browserLoad: async (canvas, size, lost) => {
        const {createWorldlineRenderer} = await import("../worldline/renderer")
        const gpu = await createWorldlineRenderer(canvas, size, lost)
        return {
          gpu,
          resize: (w, h) => gpu.resize(w, h),
          step: () => advance(performance.now()),
          present: () => {
            if (changed) {
              const packed = pack(layout)
              gpu.load(packed.segments, packed.points)
              changed = false
            }
            gpu.present({
              now: now(),
              left: right - span,
              perPx: span / width,
              orbit,
              revealed: motion.revealed,
              focus: focus ?? -1,
              emphasis: motion.emphasis,
              arrivedFrom: motion.arrivedFrom,
              arrival: motion.arrival,
            })
            placeLink()
          },
          settled: () => gpu.settled(),
          dispose: () => gpu.dispose(),
        }
      },
      interact: island => {
        nudge = island.nudge
        const canvas = island.canvas()
        const measure = () => {
          const box = canvas.getBoundingClientRect()
          width = Math.max(1, box.width)
          height = Math.max(1, box.height)
          if (following) follow()
        }
        measure()
        island.onReady(() => {
          island.renderer()?.gpu.tones(tones())
          changed = true
        })
        island.onStrain(hold => {
          strained = hold
          island.nudge()
        })

        const listening = new AbortController()
        const options = {signal: listening.signal}
        const local = (event: PointerEvent | WheelEvent) => {
          const box = canvas.getBoundingClientRect()
          return {x: event.clientX - box.left, y: event.clientY - box.top}
        }
        const pointers = new Map<number, {x: number; y: number}>()
        // A press on the picture: where it last was, how far it has moved, when,
        // and how fast it was going, in CSS pixels a millisecond.
        let drag: {x: number; moved: number; at: number; id: number; speed: number} | undefined
        let pinch: number | undefined
        const apart = () => {
          const [a, b] = [...pointers.values()]
          return Math.hypot(a.x - b.x, a.y - b.y)
        }

        root.addEventListener(
          "pointerdown",
          event => {
            if (event.button !== 0) return
            const at = local(event)
            pointers.set(event.pointerId, at)
            velocity = 0
            if (pointers.size === 1) drag = {x: at.x, moved: 0, at: event.timeStamp, id: event.pointerId, speed: 0}
            if (pointers.size === 2) {
              drag = undefined
              pinch = apart()
            }
          },
          options,
        )

        root.addEventListener(
          "pointermove",
          event => {
            const at = local(event)
            if (!pointers.has(event.pointerId)) {
              // The mark shown stays while the pointer is on its link, card and all.
              const onLink = link.contains(event.target as Node)
              if (event.pointerType === "mouse" && focusBy !== "key" && !onLink)
                choose(nearest(layout.placed, view(), orbit, at.x, at.y, NEAR), "pointer")
              return
            }
            pointers.set(event.pointerId, at)
            if (pinch !== undefined && pointers.size === 2) {
              const distance = apart()
              const [a, b] = [...pointers.values()]
              zoom((a.x + b.x) / 2, pinch / Math.max(1, distance))
              pinch = distance
              island.nudge()
            } else if (drag && drag.id === event.pointerId) {
              const dx = at.x - drag.x
              const dt = Math.max(1, event.timeStamp - drag.at)
              drag.moved += Math.abs(dx)
              if (drag.moved > DRAG && !root.hasPointerCapture(event.pointerId)) {
                root.setPointerCapture(event.pointerId)
                root.dataset.dragging = "true"
              }
              pan(dx)
              drag.speed = 0.8 * (dx / dt) + 0.2 * drag.speed
              drag.x = at.x
              drag.at = event.timeStamp
              island.nudge()
            }
          },
          options,
        )

        const release = (event: PointerEvent) => {
          if (!pointers.delete(event.pointerId)) return
          if (pointers.size < 2) pinch = undefined
          if (drag?.id === event.pointerId) {
            if (drag.moved <= DRAG && event.pointerType !== "mouse") {
              const at = local(event)
              choose(nearest(layout.placed, view(), orbit, at.x, at.y, NEAR_TOUCH), "pointer")
            }
            // A pan let go while still moving glides on, unless motion was turned down.
            const recent = event.timeStamp - drag.at < 80
            const glides = drag.moved > DRAG && recent && !still(root) && event.type !== "pointercancel"
            velocity = glides ? drag.speed : 0
            drag = undefined
          }
          delete root.dataset.dragging
          island.nudge()
        }
        root.addEventListener("pointerup", release, options)
        root.addEventListener("pointercancel", release, options)
        root.addEventListener(
          "pointerleave",
          event => {
            if (event.pointerType === "mouse" && focusBy === "pointer" && !pointers.size) choose(undefined, "pointer")
          },
          options,
        )

        root.addEventListener(
          "wheel",
          event => {
            event.preventDefault()
            const lines = event.deltaMode === WheelEvent.DOM_DELTA_LINE ? 16 : 1
            const dx = event.deltaX * lines
            const dy = event.deltaY * lines
            velocity = 0
            if (Math.abs(dx) > Math.abs(dy)) pan(-dx)
            else zoom(local(event).x, Math.exp(dy * (event.ctrlKey ? 0.01 : 0.0015)))
            island.nudge()
          },
          {signal: listening.signal, passive: false},
        )

        root.addEventListener(
          "keydown",
          event => {
            if (event.target !== root || event.altKey || event.metaKey || event.ctrlKey) return
            const step = width * KEY_PAN
            switch (event.key) {
              case "ArrowLeft":
                pan(step)
                break
              case "ArrowRight":
                pan(-step)
                break
              case "+":
              case "=":
                zoom(width / 2, KEY_ZOOM)
                break
              case "-":
              case "_":
                zoom(width / 2, 1 / KEY_ZOOM)
                break
              case "Home": {
                const first = oldest()
                if (first === undefined) return
                right = first + span * 0.95
                following = false
                hold()
                break
              }
              case "End":
                follow()
                break
              case "Enter":
                if (focus === undefined) return
                link.click()
                break
              case "Escape":
                choose(undefined, "key")
                break
              default:
                return
            }
            event.preventDefault()
            velocity = 0
            if (event.key !== "Escape" && event.key !== "Enter") chooseMiddle()
            island.nudge()
          },
          options,
        )
        root.addEventListener(
          "focus",
          () => {
            if (root.matches(":focus-visible")) chooseMiddle()
          },
          options,
        )
        root.addEventListener(
          "focusout",
          event => {
            if (!root.contains(event.relatedTarget as Node | null) && focusBy === "key") choose(undefined, "key")
          },
          options,
        )

        const forget = watchTheme(() => {
          island.renderer()?.gpu.tones(tones())
          island.nudge()
        })
        const resized = new ResizeObserver(() => {
          measure()
          island.nudge()
        })
        resized.observe(canvas)

        return () => {
          listening.abort()
          forget()
          resized.disconnect()
          nudge = () => {}
        }
      },
    })
    this.controller.mount()

    this.cleanup = () => {
      for (const animation of running) animation.cancel()
      running.clear()
    }
  },
  disconnected(this: WorldlineHook) {
    this.controller?.pause()
  },
  reconnected(this: WorldlineHook) {
    this.controller?.resume()
  },
  destroyed(this: WorldlineHook) {
    this.cleanup?.()
    this.controller?.destroy()
    this.controller = undefined
  },
}
