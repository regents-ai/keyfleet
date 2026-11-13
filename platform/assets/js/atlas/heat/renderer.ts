/**
 * Draws the Atlas heat with WebGPU through vgpu, only when something changed:
 * there is no clock and no idle loop. Moving the camera, a level fading in or
 * new counts ask for a frame (`nudge`), and nothing else does.
 *
 * Two layers of squares, one quad an instance each, so a level can fade into
 * the next: each reaches the GPU only when its squares change, from an array
 * the stage keeps. A frame writes nothing but each draw's few numbers, from
 * one array made once, so drawing allocates nothing.
 */
import {prepareShader} from "@vgpu/wgsl/prepare"
import {draw, frame, geometry, init, surface, type Buffer, type Draw, type Frame, type FramePass, type Geometry} from "vgpu"

import type {IslandRenderer} from "../../canvas_island"
import {heatWgsl} from "./shader"

type Rgb = readonly [number, number, number]

/** As many squares as one layer draws: three screens' width of the rows near the view. */
export const MAX_CELLS = 16_384

/** Floats a square takes: its start past the layer's base hour, its length, its row and its heat. */
export const CELL_FLOATS = 4

// The shader's `Params`: ten vec4s.
const PARAMS = 40

export type HeatRenderer = IslandRenderer & {
  /** An empty square's colour, the scale from a little work to the most, and the chosen square's ring. */
  tones(empty: Rgb, low: Rgb, middle: Rgb, high: Rgb, ring: Rgb): void
  /** Layer `layer`'s squares: the first `count` of `data`. */
  cells(layer: number, data: Float32Array<ArrayBuffer>, count: number): void
  /** The hour each square of layer `layer` is placed from, and how strongly the layer is drawn. */
  layer(layer: number, base: number, strength: number): void
  /**
   * The hour at the middle of the canvas, CSS pixels an hour, the first row's
   * top, each row's height, how many rows there are, which one the grid
   * leaves out (-1 for none) and how tall the band of times along the top is.
   */
  view(hour: number, zoom: number, top: number, row: number, rows: number, skip: number, band: number): void
  /** The empty squares' length in hours, and the hour they are counted from. */
  grid(hours: number, base: number): void
  /** The chosen square: its layer (-1 for none), its first hour and its row. */
  pick(layer: number, at: number, row: number): void
}

export async function createHeatRenderer(
  canvas: HTMLCanvasElement,
  size: readonly [number, number],
  onDeviceLost: () => void,
): Promise<HeatRenderer> {
  // Device pixels per CSS pixel, which the island may have capped below the screen's own.
  let scale = 1
  let width = size[0]
  let height = size[1]
  let hour = 0
  let zoom = 1
  let top = 0
  let row = 1
  let rows = 0
  let skip = -1
  let band = 0
  let gridHours = 1
  let gridBase = 0
  let picked = -1
  let pickAt = 0
  let pickRow = 0
  const tones = new Float32Array(20)
  const bases = [0, 0]
  const strengths = [0, 0]
  const counts = [0, 0]
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
      label: "atlas-heat",
    })
    stage.resize([width, height])
    const shader = prepareShader(heatWgsl, "atlas-heat.wgsl")
    const uniform = (label: string): Buffer => {
      const buffer = gpu.device.createBuffer({size: PARAMS * 4, usage: ["uniform", "copy_dst"], label})
      owned.push(buffer)
      return buffer
    }

    const quads: Geometry[] = []
    const layers: {draw: Draw; params: Buffer; call: {instances: number}}[] = []
    for (const index of [0, 1]) {
      const quad = geometry(gpu, {
        topology: "triangle-strip",
        label: `atlas-heat.cells-${index}`,
        buffers: [
          {
            stepMode: "instance",
            data: new Float32Array(MAX_CELLS * CELL_FLOATS),
            attributes: {cell: {format: "float32x4", location: 0}},
          },
        ],
      })
      owned.push(quad)
      quads.push(quad)
      const buffer = uniform(`atlas-heat.cells-${index}.params`)
      const cells = draw(gpu, {
        shader,
        geometry: quad,
        blend: "premultiplied",
        vertices: 4,
        label: `atlas-heat.cells-${index}`,
        set: {params: buffer},
      })
      await cells.compile(stage)
      layers.push({draw: cells, params: buffer, call: {instances: 0}})
    }

    const gridParams = uniform("atlas-heat.grid.params")
    const empty = draw(gpu, {
      shader,
      blend: "premultiplied",
      vertices: 3,
      entry: {vertex: "vs_grid", fragment: "fs_grid"},
      label: "atlas-heat.grid",
      set: {params: gridParams},
    })
    await empty.compile(stage)

    const unsubscribe = stage.onResize(resized => {
      scale = resized.width / Math.max(1, canvas.clientWidth)
      width = resized.width
      height = resized.height
    })

    // One draw's numbers: everything shared, then its own base, strength and pick.
    const write = (target: Buffer, base: number, strength: number, pick: boolean) => {
      params[0] = width
      params[1] = height
      params[2] = scale
      params[3] = strength
      params[4] = base - hour
      params[5] = zoom
      params[6] = top
      params[7] = row
      params[8] = gridHours
      params[9] = (((-gridBase) % gridHours) + gridHours) % gridHours
      params[10] = rows
      params[11] = width / scale / 2
      params[12] = band
      params[13] = skip
      params[16] = pickAt - base
      params[17] = pickRow
      params[18] = pick ? 1 : 0
      params.set(tones, 20)
      target.write(params)
    }

    // Made once, so a frame makes no closures of its own.
    const body = (pass: FramePass) => {
      pass.draw(empty)
      for (const layer of layers) {
        if (layer.call.instances > 0) pass.draw(layer.draw, layer.call)
      }
    }
    const record = (current: Frame) => current.pass(stage, body)

    return {
      tones(emptyTone, low, middle, high, ring) {
        tones.set(emptyTone, 0)
        tones[3] = 1
        tones.set(low, 4)
        tones.set(middle, 8)
        tones.set(high, 12)
        tones.set(ring, 16)
      },
      cells(layer, data, count) {
        counts[layer] = Math.min(count, MAX_CELLS)
        if (counts[layer] > 0) quads[layer].write(data.subarray(0, counts[layer] * CELL_FLOATS))
      },
      layer(layer, base, strength) {
        bases[layer] = base
        strengths[layer] = strength
      },
      view(at, perHour, first, each, total, left, axis) {
        hour = at
        zoom = perHour
        top = first
        row = each
        rows = total
        skip = left
        band = axis
      },
      grid(hours, base) {
        gridHours = hours
        gridBase = base
      },
      pick(layer, at, which) {
        picked = layer
        pickAt = at
        pickRow = which
      },
      resize(nextWidth, nextHeight) {
        stage.resize([nextWidth, nextHeight])
      },
      step() {
        return false
      },
      present() {
        write(gridParams, gridBase, 1, false)
        layers.forEach((layer, index) => {
          const shown = strengths[index] > 0.001 ? counts[index] : 0
          layer.call.instances = shown
          if (shown > 0) write(layer.params, bases[index], strengths[index], picked === index)
        })
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
