/*!
 * Drag and inertia adapted from thiings-grid, https://github.com/charlieclark/thiings-grid
 * at a1607d3cee9e6969f5f504f0c253ee94aa50bf54. MIT License, Copyright (c) 2025 Charlie Clark.
 * See THIRD_PARTY_NOTICES.md.
 */

// Release velocity keeps the last five pointer samples, weighted 2^i toward the
// most recent, and is dropped when the finger rested before letting go.
const historySize = 5
const restBeforeRelease = 100
// Samples are px/ms; the coast integrates px per 60 Hz frame.
const velocityScale = 16
// Per-millisecond friction, applied as friction^dt.
const friction = 0.997
const minVelocity = 0.05
const focusDuration = 400
// How far a press may travel and still count as a tap.
const tapTravel: Record<string, number> = {mouse: 6, pen: 6, touch: 10}

export type Camera = {
  /** The world point at the centre of the stage. */
  x: number
  y: number
  /** Moves the camera now. */
  jumpTo(x: number, y: number): void
  /** Eases the camera to a point, or jumps there under reduced motion. */
  glideTo(x: number, y: number): void
  /** Where the camera is gliding to, or where it is. */
  heading(): [number, number]
  /** Moves the camera by a whole copy of the map, which the viewer never sees. */
  shift(dx: number, dy: number): void
  /** Rescales every position, glide included, when the cell size changes. */
  scale(factor: number): void
  destroy(): void
}

export type CameraOptions = {
  /** Draws the frame; runs once per animation frame while anything moves. */
  onFrame(): void
  /** A press that neither dragged nor stopped a moving map. */
  onTap(clientX: number, clientY: number): void
  reducedMotion(): boolean
}

type Drag = {
  pointerId: number
  pointerType: string
  startX: number
  startY: number
  lastX: number
  lastY: number
  lastTime: number
  travel: number
  history: [number, number][]
  stoppedTheMap: boolean
}

type Glide = {fromX: number; fromY: number; toX: number; toY: number; start: number}

export function createCamera(stage: HTMLElement, options: CameraOptions): Camera {
  let drag: Drag | null = null
  let glide: Glide | null = null
  let vx = 0
  let vy = 0
  let frame = 0
  let lastFrame = 0
  // Set when a press ended as a drag, so the browser's click that follows is dropped.
  let dragged = false

  const coasting = () => Math.hypot(vx, vy) >= minVelocity

  const tick = (now: number) => {
    frame = 0
    const dt = Math.min(64, Math.max(0, now - lastFrame))
    lastFrame = now
    if (glide) {
      const t = Math.min(1, (now - glide.start) / focusDuration)
      const eased = 1 - (1 - t) ** 3
      camera.x = glide.fromX + (glide.toX - glide.fromX) * eased
      camera.y = glide.fromY + (glide.toY - glide.fromY) * eased
      if (t === 1) glide = null
    } else if (!drag && coasting()) {
      camera.x -= (vx * dt) / velocityScale
      camera.y -= (vy * dt) / velocityScale
      const decay = friction ** dt
      vx *= decay
      vy *= decay
    }
    options.onFrame()
    if (glide || (!drag && coasting())) schedule()
  }

  const schedule = () => {
    if (!frame) frame = requestAnimationFrame(tick)
  }

  const stop = () => {
    vx = 0
    vy = 0
    glide = null
  }

  const camera: Camera = {
    x: 0,
    y: 0,
    jumpTo(x, y) {
      stop()
      camera.x = x
      camera.y = y
      schedule()
    },
    glideTo(x, y) {
      if (options.reducedMotion()) return camera.jumpTo(x, y)
      vx = 0
      vy = 0
      glide = {fromX: camera.x, fromY: camera.y, toX: x, toY: y, start: performance.now()}
      lastFrame = performance.now()
      schedule()
    },
    heading() {
      return glide ? [glide.toX, glide.toY] : [camera.x, camera.y]
    },
    scale(factor) {
      camera.x *= factor
      camera.y *= factor
      if (glide) {
        glide.fromX *= factor
        glide.toX *= factor
        glide.fromY *= factor
        glide.toY *= factor
      }
    },
    shift(dx, dy) {
      camera.x += dx
      camera.y += dy
      if (glide) {
        glide.fromX += dx
        glide.toX += dx
        glide.fromY += dy
        glide.toY += dy
      }
    },
    destroy() {
      cancelAnimationFrame(frame)
      stage.removeEventListener("pointerdown", down)
      stage.removeEventListener("pointermove", move)
      stage.removeEventListener("pointerup", up)
      stage.removeEventListener("pointercancel", cancel)
      stage.removeEventListener("lostpointercapture", cancel)
      stage.removeEventListener("wheel", wheel)
      stage.removeEventListener("click", swallowClick, true)
    },
  }

  const down = (event: PointerEvent) => {
    if (!event.isPrimary || event.button !== 0) return
    // A new press replaces a drag whose release never arrived.
    if (drag) release()
    const stoppedTheMap = coasting() || glide !== null
    dragged = false
    stop()
    stage.setPointerCapture(event.pointerId)
    stage.classList.add("key-map--dragging")
    drag = {
      pointerId: event.pointerId,
      // Browsers that cannot tell report an empty type; treat it as a mouse.
      pointerType: event.pointerType || "mouse",
      startX: event.clientX,
      startY: event.clientY,
      lastX: event.clientX,
      lastY: event.clientY,
      lastTime: performance.now(),
      travel: 0,
      history: [],
      stoppedTheMap,
    }
  }

  const move = (event: PointerEvent) => {
    if (event.pointerId !== drag?.pointerId) return
    // The mouse button came up where this element never heard it.
    if (drag.pointerType === "mouse" && event.buttons === 0) return void release()
    const now = performance.now()
    const dx = event.clientX - drag.lastX
    const dy = event.clientY - drag.lastY
    const elapsed = now - drag.lastTime || 1
    drag.history.push([dx / elapsed, dy / elapsed])
    if (drag.history.length > historySize) drag.history.shift()
    drag.travel = Math.max(drag.travel, Math.hypot(event.clientX - drag.startX, event.clientY - drag.startY))
    drag.lastX = event.clientX
    drag.lastY = event.clientY
    drag.lastTime = now
    camera.x -= dx
    camera.y -= dy
    schedule()
  }

  const release = () => {
    const released = drag
    drag = null
    stage.classList.remove("key-map--dragging")
    return released
  }

  const up = (event: PointerEvent) => {
    if (event.pointerId !== drag?.pointerId) return
    const released = release()!
    if (released.travel <= tapTravel[released.pointerType] && !released.stoppedTheMap) {
      options.onTap(event.clientX, event.clientY)
      return
    }
    dragged = true
    if (options.reducedMotion() || performance.now() - released.lastTime > restBeforeRelease) return
    let weight = 0
    let sumX = 0
    let sumY = 0
    released.history.forEach(([x, y], index) => {
      weight += 2 ** index
      sumX += x * 2 ** index
      sumY += y * 2 ** index
    })
    if (!weight) return
    vx = (sumX / weight) * velocityScale
    vy = (sumY / weight) * velocityScale
    lastFrame = performance.now()
    schedule()
  }

  const cancel = (event: PointerEvent) => {
    if (event.pointerId === drag?.pointerId) release()
  }

  const swallowClick = (event: MouseEvent) => {
    if (!dragged) return
    dragged = false
    event.stopPropagation()
    event.preventDefault()
  }

  // Wheel and trackpad scrolling pan the map; ctrl-wheel stays the browser's zoom.
  const wheel = (event: WheelEvent) => {
    if (event.ctrlKey) return
    event.preventDefault()
    const page = event.deltaMode === WheelEvent.DOM_DELTA_PAGE
    const line = event.deltaMode === WheelEvent.DOM_DELTA_LINE ? 16 : 1
    stop()
    camera.x += event.deltaX * (page ? stage.clientWidth : line)
    camera.y += event.deltaY * (page ? stage.clientHeight : line)
    schedule()
  }

  stage.addEventListener("pointerdown", down)
  stage.addEventListener("pointermove", move)
  stage.addEventListener("pointerup", up)
  stage.addEventListener("pointercancel", cancel)
  // Losing capture any other way (the element hidden, capture released) ends the drag too.
  stage.addEventListener("lostpointercapture", cancel)
  stage.addEventListener("wheel", wheel, {passive: false})
  stage.addEventListener("click", swallowClick, true)

  return camera
}
