/**
 * Draws the homepage's hex field with WebGPU through vgpu, behind the hero and
 * the Club's map, only when something changed. There is no clock and no idle
 * loop. A pointer or a preview sets a target, the picture eases toward it for a
 * few frames and stops. Loaded only once a picture is really going to be shown.
 *
 * Each value reaches the shader when it changes: the size when the canvas is
 * resized, the colours when the theme changes, the pointer on each frame.
 */
import {prepareShader} from "@vgpu/wgsl/prepare"
import {effect, frame, init, surface} from "vgpu"

import type {IslandRenderer} from "../canvas_island"
import {fieldWgsl} from "./shader"

export type Rgb = readonly [number, number, number]
type Vec4 = [number, number, number, number]

/** How far one frame closes the gap to a target, and when the gap counts as closed. */
const EASE = 0.2
const CLOSE = 0.002

/** One eased value: where it is, and where it is going. */
const eased = (value = 0) => ({value, target: value})
type Eased = ReturnType<typeof eased>

/** Moves every value one frame toward its target, or onto it. True when anything moved. */
const advance = (values: Eased[], snap: boolean) => {
  let moved = false
  for (const v of values) {
    const gap = v.target - v.value
    if (gap === 0) continue
    v.value = snap || Math.abs(gap) < CLOSE ? v.target : v.value + gap * EASE
    moved = true
  }
  return moved
}

type Params = Record<string, Vec4>
type Shader = ReturnType<typeof effect>

/**
 * One premultiplied effect on one canvas, with its GPU housekeeping.
 * `params` is the complete uniform struct the shader starts from; `sized` hears
 * every size, the first one included, and writes what depends on it.
 */
async function paint(
  canvas: HTMLCanvasElement,
  size: readonly [number, number],
  onDeviceLost: () => void,
  name: string,
  source: string,
  params: Params,
  sized: (shader: Shader, width: number, height: number) => void,
) {
  const gpu = await init()
  let disposed = false
  // Disposing the device resolves the same promise, so only a picture still
  // on screen reports a loss.
  void gpu.lost.then(() => {
    if (!disposed) onDeviceLost()
  })
  try {
    const stage = surface(gpu, canvas, {autoResize: false, alphaMode: "premultiplied", label: name})
    stage.resize([size[0], size[1]])
    const shader = effect(gpu, prepareShader(source, `${name}.wgsl`), {label: `${name}.pass`, set: {params}})
    await shader.compile({colors: [stage.format]})
    const unsubscribe = stage.onResize(({width, height}) => sized(shader, width, height))
    return {
      shader,
      resize(width: number, height: number) {
        stage.resize([width, height])
      },
      draw() {
        frame(gpu, current => current.pass(stage, shader))
      },
      async settled() {
        await gpu.gpu.queue.onSubmittedWorkDone()
        await gpu.settled()
      },
      dispose() {
        if (disposed) return
        disposed = true
        unsubscribe()
        stage.dispose()
        gpu.dispose()
      },
    }
  } catch (error) {
    gpu.dispose()
    throw error
  }
}

export type FieldRenderer = IslandRenderer & {
  /** The lines' colour and the preview's light, from the page's theme. */
  tones(line: Rgb, light: Rgb): void
  /** Where the pointer stands, 0..1 across the canvas. */
  point(x: number, y: number): void
  /** The pointer left. */
  rest(): void
  /** Where the Key sits, 0..1 across the canvas, and how far its light reaches in CSS pixels. */
  key(x: number, y: number, reach: number): void
  /** Whether the Key is being previewed. */
  lit(on: boolean): void
}

/** `cell` is the distance between neighbouring tiles in CSS pixels, read at each new size. */
export async function createFieldRenderer(
  canvas: HTMLCanvasElement,
  size: readonly [number, number],
  onDeviceLost: () => void,
  cell: () => number,
): Promise<FieldRenderer> {
  // Device pixels per CSS pixel, so the tiles and the Key's reach keep their
  // CSS size at any screen density.
  let ratio = 1
  let key: Vec4 = [0.5, 0.5, 0, 0]
  const placed = (): Vec4 => [key[0], key[1], key[2] * ratio, 0]
  const gpu = await paint(
    canvas,
    size,
    onDeviceLost,
    "home-field",
    fieldWgsl,
    {
      size: [size[0], size[1], cell(), 0],
      line: [1, 1, 1, 1],
      light: [1, 1, 1, 1],
      pointer: [0.5, 0.5, 0, 0],
      key: placed(),
    },
    (shader, width, height) => {
      ratio = width / Math.max(1, canvas.clientWidth)
      shader.set({params: {size: [width, height, cell() * ratio, 0], key: placed()}})
    },
  )
  const x = eased(0.5)
  const y = eased(0.5)
  const presence = eased()
  const glow = eased()
  // The pointer's first position is taken as it is, so the light appears
  // where the pointer is instead of sliding in from the last place it left.
  const jump = (value: Eased, to: number) => {
    value.target = to
    if (presence.value === 0) value.value = to
  }

  return {
    tones(line, light) {
      gpu.shader.set({params: {line: [...line, 1], light: [...light, 1]}})
    },
    point(px, py) {
      jump(x, px)
      jump(y, py)
      presence.target = 1
    },
    rest() {
      presence.target = 0
    },
    key(kx, ky, reach) {
      key = [kx, ky, reach, 0]
      gpu.shader.set({params: {key: placed()}})
    },
    lit(on) {
      glow.target = on ? 1 : 0
    },
    resize: gpu.resize,
    step: snap => advance([x, y, presence, glow], snap),
    present() {
      gpu.shader.set({params: {pointer: [x.value, y.value, presence.value, glow.value]}})
      gpu.draw()
    },
    settled: gpu.settled,
    dispose: gpu.dispose,
  }
}
