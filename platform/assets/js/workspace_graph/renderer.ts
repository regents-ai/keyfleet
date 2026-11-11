/**
 * Draws the workspace graph's links with WebGPU through vgpu, under the
 * items the page drew, only when something changed. There is no clock and
 * no idle loop: pointing at an item sets which links should light, the
 * picture eases toward it for a few frames and stops.
 *
 * The links reach the GPU once each time the page's graph changes, one
 * instance each; only how lit each one is changes from frame to frame.
 */
import {prepareShader} from "@vgpu/wgsl/prepare"
import {draw, frame, geometry, init, surface} from "vgpu"

import type {IslandRenderer} from "../canvas_island"
import {graphWgsl} from "./shader"

type Rgb = readonly [number, number, number]

/**
 * One link: its start, two handles and end, in points of the picture,
 * whether it contradicts, and whether it is dashed, as a fork, a review or a
 * contradiction is.
 */
export type Link = {
  readonly points: readonly number[]
  readonly against: boolean
  readonly dashed: boolean
}

// About how long a curve runs, in points: between its chord and the path
// through its handles, which is near enough to space its dashes.
const length = ([x1, y1, c1x, c1y, c2x, c2y, x2, y2]: readonly number[]) => {
  const chord = Math.hypot(x2 - x1, y2 - y1)
  const hull =
    Math.hypot(c1x - x1, c1y - y1) + Math.hypot(c2x - c1x, c2y - c1y) + Math.hypot(x2 - c2x, y2 - c2y)
  return (chord + hull) / 2
}

/** As many links as the workspace's graph read answers. */
export const MAX_LINKS = 600

const SEGMENTS = 32
const FLOATS = 12

/** How far one frame closes the gap to a target, and when the gap counts as closed. */
const EASE = 0.25
const CLOSE = 0.002

export type GraphRenderer = IslandRenderer & {
  /** The resting links' colour and strength, the lit ones' colour and a contradicting one's. */
  tones(ink: Rgb, strength: number, lit: Rgb, against: Rgb): void
  /** The links to draw, as the page laid them out. */
  links(links: readonly Link[]): void
  /** Which links should be lit, by their place in `links`. */
  light(lit: ReadonlySet<number>): void
}

export async function createGraphRenderer(
  canvas: HTMLCanvasElement,
  size: readonly [number, number],
  onDeviceLost: () => void,
): Promise<GraphRenderer> {
  // Device pixels per point of the picture, which the island may have
  // capped below the screen's own.
  let scale = 1
  let pixels: readonly [number, number] = [size[0], size[1]]
  let count = 0
  const data = new Float32Array(MAX_LINKS * FLOATS)
  const lights = Array.from({length: MAX_LINKS}, () => ({value: 0, target: 0}))
  const recede = {value: 0, target: 0}

  const gpu = await init()
  let disposed = false
  // Disposing the device resolves the same promise, so only a picture still
  // on screen reports a loss.
  void gpu.lost.then(() => {
    if (!disposed) onDeviceLost()
  })

  try {
    const stage = surface(gpu, canvas, {
      autoResize: false,
      alphaMode: "premultiplied",
      clearColor: [0, 0, 0, 0],
      label: "workspace-graph",
    })
    stage.resize([size[0], size[1]])
    const strips = geometry(gpu, {
      topology: "triangle-strip",
      label: "workspace-graph.links",
      buffers: [
        {
          stepMode: "instance",
          data,
          attributes: {
            a: {format: "float32x4", location: 0},
            b: {format: "float32x4", location: 1},
            c: {format: "float32x4", location: 2},
          },
        },
      ],
    })
    const ribbons = draw(gpu, {
      shader: prepareShader(graphWgsl, "workspace-graph.wgsl"),
      geometry: strips,
      blend: "premultiplied",
      vertices: (SEGMENTS + 1) * 2,
      label: "workspace-graph.pass",
      set: {
        params: {
          size: [size[0], size[1], 1, 0],
          ink: [0.5, 0.5, 0.5, 0.5],
          lit: [1, 1, 1, 1],
          against: [1, 0, 0, 1],
        },
      },
    })
    await ribbons.compile(stage)
    const unsubscribe = stage.onResize(({width, height}) => {
      scale = width / Math.max(1, canvas.clientWidth)
      pixels = [width, height]
    })

    return {
      tones(ink, strength, lit, against) {
        ribbons.set({params: {ink: [...ink, strength], lit: [...lit, 1], against: [...against, 1]}})
      },
      links(links) {
        count = Math.min(links.length, MAX_LINKS)
        data.fill(0)
        links.slice(0, count).forEach((link, i) => {
          data.set(link.points.slice(0, 8), i * FLOATS)
          data[i * FLOATS + 9] = link.against ? 1 : 0
          data[i * FLOATS + 10] = link.dashed ? length(link.points) : 0
        })
        for (const light of lights) light.value = light.target = 0
        recede.value = recede.target = 0
      },
      light(lit) {
        lights.forEach((light, i) => (light.target = lit.has(i) ? 1 : 0))
        recede.target = lit.size > 0 ? 1 : 0
      },
      resize(width, height) {
        stage.resize([width, height])
      },
      step(snap) {
        let moved = false
        for (const eased of [recede, ...lights.slice(0, count)]) {
          const gap = eased.target - eased.value
          if (gap === 0) continue
          eased.value = snap || Math.abs(gap) < CLOSE ? eased.target : eased.value + gap * EASE
          moved = true
        }
        return moved
      },
      present() {
        for (let i = 0; i < count; i++) data[i * FLOATS + 8] = lights[i].value
        strips.write(data)
        ribbons.set({params: {size: [pixels[0], pixels[1], scale, recede.value]}})
        frame(gpu, current =>
          current.pass(stage, pass => {
            if (count > 0) pass.draw(ribbons, {instances: count})
          }),
        )
      },
      settled() {
        return gpu.settled()
      },
      dispose() {
        if (disposed) return
        disposed = true
        unsubscribe()
        strips.destroy()
        stage.dispose()
        gpu.dispose()
      },
    }
  } catch (error) {
    // Set first, so the loss that disposing the device reports is not taken
    // for one to recover from.
    disposed = true
    gpu.dispose()
    throw error
  }
}
