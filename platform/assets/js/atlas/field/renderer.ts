/**
 * Draws the Atlas field with WebGPU through vgpu, only when something
 * changed: there is no clock and no idle loop. Moving the camera or new
 * counts ask for a frame (`nudge`), and nothing else does.
 *
 * Three layers, one quad an instance each: the glows of the fleet's scale,
 * the blocks of hours, and the points of things. Each reaches the GPU only
 * when its instances change, from an array the stage keeps; a frame writes
 * nothing but each draw's few numbers, from one array made once, so drawing
 * allocates nothing.
 */
import {prepareShader} from "@vgpu/wgsl/prepare"
import {draw, frame, geometry, init, surface, type Buffer, type Draw, type Frame, type FramePass, type Geometry} from "vgpu"

import type {IslandRenderer} from "../../canvas_island"
import {fieldWgsl} from "./shader"

type Rgb = readonly [number, number, number]

/** The layers, back to front, by the shape each draws. */
export const GLOW = 0
export const BLOCKS = 1
export const POINTS = 2

/** As many instances as one layer draws. */
export const MAX_SHAPES = 65_536

/** Floats an instance takes: its corner and size in world units past the layer's base, and its value. */
export const SHAPE_FLOATS = 5

// The shader's `Params`: seven vec4s.
const PARAMS = 28

export type FieldRenderer = IslandRenderer & {
  /** The ground of a kind's hours, and the scale from a little work to the most. */
  tones(ground: Rgb, low: Rgb, middle: Rgb, high: Rgb): void
  /** Layer `layer`'s instances: the first `count` of `data`. */
  shapes(layer: number, data: Float32Array<ArrayBuffer>, count: number): void
  /** The world point layer `layer` is placed from, and how strongly it is drawn. */
  layer(layer: number, x: number, y: number, strength: number): void
  /** The world point at the middle of the canvas, and CSS pixels a world unit. */
  view(x: number, y: number, zoom: number): void
}

export async function createFieldRenderer(
  canvas: HTMLCanvasElement,
  size: readonly [number, number],
  onDeviceLost: () => void,
): Promise<FieldRenderer> {
  // Device pixels per CSS pixel, which the island may have capped below the screen's own.
  let scale = 1
  let width = size[0]
  let height = size[1]
  let x = 0
  let y = 0
  let zoom = 1
  const tones = new Float32Array(16)
  const bases = [0, 0, 0, 0, 0, 0]
  const strengths = [0, 0, 0]
  const counts = [0, 0, 0]
  const params = new Float32Array(PARAMS)

  const gpu = await init()
  let disposed = false
  // Disposing the device resolves the same promise, so only a picture still
  // on screen reports a loss.
  void gpu.lost.then(() => {
    if (!disposed) onDeviceLost()
  })

  const owned: {destroy(): void}[] = []
  try {
    const stage = surface(gpu, canvas, {
      autoResize: false,
      alphaMode: "premultiplied",
      clearColor: [0, 0, 0, 0],
      label: "atlas-field",
    })
    stage.resize([width, height])
    const shader = prepareShader(fieldWgsl, "atlas-field.wgsl")

    const quads: Geometry[] = []
    const layers: {draw: Draw; params: Buffer; call: {instances: number}}[] = []
    for (const index of [GLOW, BLOCKS, POINTS]) {
      const quad = geometry(gpu, {
        topology: "triangle-strip",
        label: `atlas-field.layer-${index}`,
        buffers: [
          {
            stepMode: "instance",
            data: new Float32Array(MAX_SHAPES * SHAPE_FLOATS),
            attributes: {
              rect: {format: "float32x4", location: 0},
              value: {format: "float32", location: 1},
            },
          },
        ],
      })
      owned.push(quad)
      quads.push(quad)
      const buffer = gpu.device.createBuffer({
        size: PARAMS * 4,
        usage: ["uniform", "copy_dst"],
        label: `atlas-field.layer-${index}.params`,
      })
      owned.push(buffer)
      const shapes = draw(gpu, {
        shader,
        geometry: quad,
        blend: "premultiplied",
        vertices: 4,
        label: `atlas-field.layer-${index}`,
        set: {params: buffer},
      })
      await shapes.compile(stage)
      layers.push({draw: shapes, params: buffer, call: {instances: 0}})
    }

    const unsubscribe = stage.onResize(resized => {
      scale = resized.width / Math.max(1, canvas.clientWidth)
      width = resized.width
      height = resized.height
    })

    const write = (index: number) => {
      params[0] = width
      params[1] = height
      params[2] = scale
      params[3] = strengths[index]
      params[4] = bases[index * 2] - x
      params[5] = bases[index * 2 + 1] - y
      params[6] = zoom
      params[7] = index
      params[8] = width / scale / 2
      params[9] = height / scale / 2
      params.set(tones, 12)
      layers[index].params.write(params)
    }

    // Made once, so a frame makes no closures of its own.
    const body = (pass: FramePass) => {
      for (const layer of layers) {
        if (layer.call.instances > 0) pass.draw(layer.draw, layer.call)
      }
    }
    const record = (current: Frame) => current.pass(stage, body)

    return {
      tones(ground, low, middle, high) {
        tones.set(ground, 0)
        tones[3] = 0.55
        tones.set(low, 4)
        tones.set(middle, 8)
        tones.set(high, 12)
      },
      shapes(layer, data, count) {
        counts[layer] = Math.min(count, MAX_SHAPES)
        if (counts[layer] > 0) quads[layer].write(data.subarray(0, counts[layer] * SHAPE_FLOATS))
      },
      layer(layer, baseX, baseY, strength) {
        bases[layer * 2] = baseX
        bases[layer * 2 + 1] = baseY
        strengths[layer] = strength
      },
      view(atX, atY, perUnit) {
        x = atX
        y = atY
        zoom = perUnit
      },
      resize(nextWidth, nextHeight) {
        stage.resize([nextWidth, nextHeight])
      },
      step() {
        return false
      },
      present() {
        for (let index = 0; index < layers.length; index++) {
          const shown = strengths[index] > 0.001 ? counts[index] : 0
          layers[index].call.instances = shown
          if (shown > 0) write(index)
        }
        frame(gpu, record)
      },
      settled() {
        return gpu.settled()
      },
      dispose() {
        if (disposed) return
        disposed = true
        unsubscribe()
        for (const resource of owned) resource.destroy()
        stage.dispose()
        gpu.dispose()
      },
    }
  } catch (error) {
    // Set first, so the loss that disposing the device reports is not taken
    // for one to recover from.
    disposed = true
    for (const resource of owned) resource.destroy()
    gpu.dispose()
    throw error
  }
}
