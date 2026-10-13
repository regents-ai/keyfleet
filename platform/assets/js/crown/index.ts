/**
 * The crown renderer, loaded on demand by the page that shows it.
 *
 * Everything WebGPU lives behind this module so the application entry never
 * carries it. The renderer owns the device, the surface and the scene; the page
 * owns the canvas box, when a frame is worth drawing, and the still picture the
 * visitor sees until one really lands.
 *
 * Derived from the Vercel vgpu prism background. See THIRD_PARTY_NOTICES.md.
 */

import {init, surface} from "vgpu"

import {
  CAMERA_ORBIT_LERP,
  CROWN_TINT_LERP,
  quadrantTint,
  quantizeCrownAim,
  type CrownBeamTint,
  type CrownLook,
  type CrownStyle,
  type Vec2,
  type Vec3,
} from "./look"
import {createCrownScene} from "./scene"

export interface CrownRenderer {
  /** Pointer position over the crown's stage, both components in [0, 1]. */
  aim(x: number, y: number): void
  /**
   * The pointer's own place over the stage, both components in [0, 1]. A look
   * with quadrants eases its beams to the tint of the quarter the pointer is in.
   */
  point(x: number, y: number): void
  /** The pointer left: ease everything back to the composed shot. */
  rest(): void
  /** Changes glass, bloom and beams without rebuilding the crown. */
  restyle(style: CrownStyle): void
  resize(width: number, height: number): void
  /** Advances the easing one frame, or snaps it home. True when the picture moved. */
  step(snap: boolean): boolean
  present(): void
  /** Resolves once the work submitted so far has finished on the GPU. */
  settled(): Promise<void>
  dispose(): void
}

const AT_REST: Vec2 = [0, 0]
const clampUnit = (value: number): number => Math.min(1, Math.max(0, value))

/** The next easing position, or nothing when this pair has already arrived. */
function stepPair(current: Vec2, target: Vec2, rate: number, snap: boolean): Vec2 | undefined {
  const dx = target[0] - current[0]
  const dy = target[1] - current[1]
  if (dx === 0 && dy === 0) return undefined
  if (snap || (Math.abs(dx) < 1e-4 && Math.abs(dy) < 1e-4)) return target
  return [current[0] + dx * rate, current[1] + dy * rate]
}

const TINT_PARTS = ["input", "internal", "fan"] as const
/** A difference in a colour channel too small to see. */
const TINT_ARRIVED = 1 / 512

/** The next tint on the way to the target, or nothing when this one has arrived. */
function stepTint(
  current: CrownBeamTint,
  target: CrownBeamTint,
  snap: boolean,
): CrownBeamTint | undefined {
  if (current === target) return undefined
  const far = TINT_PARTS.some(part =>
    current[part].some((channel, index) => Math.abs(target[part][index]! - channel) >= TINT_ARRIVED),
  )
  if (snap || !far) return target
  const eased = (part: (typeof TINT_PARTS)[number]): Vec3 => {
    const [r, g, b] = current[part]
    const [targetR, targetG, targetB] = target[part]
    return [
      r + (targetR - r) * CROWN_TINT_LERP,
      g + (targetG - g) * CROWN_TINT_LERP,
      b + (targetB - b) * CROWN_TINT_LERP,
    ]
  }
  return {input: eased("input"), internal: eased("internal"), fan: eased("fan")}
}

export async function createCrownRenderer(
  canvas: HTMLCanvasElement,
  size: readonly [number, number],
  onDeviceLost: () => void,
  look: CrownLook,
): Promise<CrownRenderer> {
  const gpu = await init()
  let disposed = false
  // Disposing the device resolves the same promise, so only a crown still on
  // screen reports a loss.
  void gpu.lost.then(() => {
    if (!disposed) onDeviceLost()
  })

  const stage = surface(gpu, canvas, {autoResize: false, label: "crown"})
  stage.resize([size[0], size[1]])
  // A device this call made and could not finish equipping is still this call's
  // to release; the page only ever learns that the renderer did not arrive.
  const scene = await createCrownScene(gpu, stage, look, "crown").catch(error => {
    disposed = true
    stage.dispose()
    gpu.dispose()
    throw error
  })

  let style: CrownStyle = look
  let orbitTarget = AT_REST
  let orbitCurrent = AT_REST
  let aimApplied = AT_REST
  let tintTarget: CrownBeamTint = style.colors
  let tintCurrent: CrownBeamTint = style.colors

  return {
    // Pointer motion is decorative: it turns the camera and swings the beams.
    aim(x, y) {
      orbitTarget = [clampUnit(x) * 2 - 1, clampUnit(y) * 2 - 1]
    },
    point(x, y) {
      if (style.quadrants) tintTarget = quadrantTint(style.quadrants, x, y)
    },
    rest() {
      orbitTarget = AT_REST
      tintTarget = style.colors
    },
    restyle(next) {
      style = next
      tintTarget = next.colors
      tintCurrent = next.colors
      scene.restyle(next)
    },
    resize(width, height) {
      stage.resize([width, height])
      scene.resize()
    },
    step(snap) {
      const nextOrbit = stepPair(orbitCurrent, orbitTarget, CAMERA_ORBIT_LERP, snap)
      if (nextOrbit) {
        orbitCurrent = nextOrbit
        scene.orbit(nextOrbit[0], nextOrbit[1])
      }
      // Every beam is retraced on the processor, so the beams follow the eased
      // camera in steps rather than at every fraction of it.
      const nextAim = quantizeCrownAim(orbitCurrent)
      const aimMoved = nextAim[0] !== aimApplied[0] || nextAim[1] !== aimApplied[1]
      if (aimMoved) {
        aimApplied = nextAim
        scene.aim(nextAim[0], nextAim[1])
      }
      const nextTint = stepTint(tintCurrent, tintTarget, snap)
      if (nextTint) {
        tintCurrent = nextTint
        scene.tint(nextTint)
      }
      return Boolean(nextOrbit) || aimMoved || Boolean(nextTint)
    },
    present() {
      scene.present()
    },
    async settled() {
      await gpu.gpu.queue.onSubmittedWorkDone()
      await gpu.settled()
    },
    dispose() {
      if (disposed) return
      disposed = true
      stage.dispose()
      gpu.dispose()
    },
  }
}
