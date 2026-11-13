/**
 * Draws the Atlas river with WebGPU through vgpu, only when something changed:
 * there is no clock and no idle loop. Moving the camera, a level fading in, a
 * band opening or new counts ask for a frame (`nudge`), and nothing else does.
 *
 * Two layers of the stream, so a level can fade into the next, then the
 * chosen band's lanes and its things' marks: each reaches the GPU only when
 * its pieces change, from an array the stage keeps. A frame writes nothing but
 * each draw's few numbers, from one array made once, so drawing allocates
 * nothing. Edges are smoothed four samples a pixel.
 */
import {prepareShader} from "@vgpu/wgsl/prepare"
import {draw, frame, geometry, init, surface, type Buffer, type Draw, type Frame, type FramePass, type Geometry} from "vgpu"

import type {IslandRenderer} from "../../canvas_island"
import {riverWgsl} from "./shader"
import {LANE_FLOATS, MARK_FLOATS, PIECE_FLOATS} from "./stream"

type Rgb = readonly [number, number, number]

/** As many pieces as one layer of the stream draws, as many lane pieces, and as many marks. */
export const MAX_PIECES = 24_576
export const MAX_LANE_PIECES = 8_192
export const MAX_MARKS = 4_096

// The shader's `Params`: fifteen vec4s.
const PARAMS = 60
// Pixels of the screen a segment of a piece spans, and the most segments a piece has.
const SEGMENT = 6
const MOST_SEGMENTS = 64

/** Everything a frame of the river is drawn from, besides its pieces. */
export type RiverView = {
  /** The hour at the middle of the canvas, and CSS pixels an hour. */
  hour: number
  zoom: number
  /** The middle of the stream, in CSS pixels down from the top, and the band of times above it. */
  middle: number
  top: number
  /** How far the chosen band has opened, and how far its lanes have. */
  open: number
  lanes: number
  /** The lanes' region, each lane's height, how far down a lane its line runs, and the lanes' scale. */
  region: number
  lane: number
  line: number
  laneScale: number
  /** How strongly the marks are drawn, how far the cards have come in, and how far a mark sits off its line. */
  marks: number
  cards: number
  spread: number
  /** The band, lane and mark under the pointer, and the chosen band: -1 for none. */
  hoverBand: number
  hoverLane: number
  hoverMark: number
  chosen: number
}

export type RiverRenderer = IslandRenderer & {
  /** The bands' two tones, the rest's, the chosen band's, the marks', the page's ground and the focus ring. */
  tones(one: Rgb, two: Rgb, rest: Rgb, pick: Rgb, mark: Rgb, note: Rgb, ground: Rgb, ring: Rgb): void
  /** Layer `layer`'s pieces: the first `count` of `data`. */
  pieces(layer: number, data: Float32Array<ArrayBuffer>, count: number): void
  /** The lanes' pieces and the marks: the first `count` of each. */
  lanes(data: Float32Array<ArrayBuffer>, count: number): void
  marks(data: Float32Array<ArrayBuffer>, count: number): void
  /**
   * Layer `layer`'s base hour, its hours between knots, how strongly it is
   * drawn, and its scales for the rest and the chosen band, in CSS pixels a change.
   */
  layer(layer: number, base: number, step: number, strength: number, ko: number, kf: number): void
  /** The lanes' and the marks' base hours, and the chosen band's scale the lanes open out of. */
  bases(lanes: number, marks: number, kf: number): void
  view(view: RiverView): void
}

export async function createRiverRenderer(
  canvas: HTMLCanvasElement,
  size: readonly [number, number],
  onDeviceLost: () => void,
): Promise<RiverRenderer> {
  // Device pixels per CSS pixel, which the island may have capped below the screen's own.
  let scale = 1
  let width = size[0]
  let height = size[1]
  let seen: RiverView | undefined
  const tones = new Float32Array(32)
  const bases = [0, 0]
  const steps = [1, 1]
  const strengths = [0, 0]
  const kos = [1, 1]
  const kfs = [1, 1]
  const counts = [0, 0]
  let [laneBase, laneKf, laneCount] = [0, 1, 0]
  let [markBase, markCount] = [0, 0]
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
      msaa: true,
      label: "atlas-river",
    })
    stage.resize([width, height])
    const shader = prepareShader(riverWgsl, "atlas-river.wgsl")
    const uniform = (label: string): Buffer => {
      const buffer = gpu.device.createBuffer({size: PARAMS * 4, usage: ["uniform", "copy_dst"], label})
      owned.push(buffer)
      return buffer
    }
    const vec4s = (names: readonly string[]) =>
      Object.fromEntries(names.map((name, location) => [name, {format: "float32x4" as const, location, offset: location * 16}]))
    const instanced = (label: string, floats: number, count: number, names: readonly string[]) => {
      const made = geometry(gpu, {
        topology: "triangle-strip",
        label,
        buffers: [{stepMode: "instance", data: new Float32Array(count * floats), attributes: vec4s(names)}],
      })
      owned.push(made)
      return made
    }

    const layers: {geometry: Geometry; draw: Draw; params: Buffer; call: {instances: number; vertices: number}}[] = []
    for (const index of [0, 1]) {
      const label = `atlas-river.stream-${index}`
      const pieces = instanced(label, PIECE_FLOATS, MAX_PIECES, [
        "head",
        "own",
        "below",
        "chosenBelow",
        "total",
        "chosen",
        "otherBelow",
      ])
      const buffer = uniform(`${label}.params`)
      const stream = draw(gpu, {
        shader,
        geometry: pieces,
        blend: "premultiplied",
        entry: {vertex: "vs_band", fragment: "fs_band"},
        label,
        set: {params: buffer},
      })
      await stream.compile(stage)
      layers.push({geometry: pieces, draw: stream, params: buffer, call: {instances: 0, vertices: 4}})
    }

    const lanePieces = instanced("atlas-river.lanes", LANE_FLOATS, MAX_LANE_PIECES, ["head", "own", "below", "band"])
    const laneParams = uniform("atlas-river.lanes.params")
    const lanes = draw(gpu, {
      shader,
      geometry: lanePieces,
      blend: "premultiplied",
      entry: {vertex: "vs_lane", fragment: "fs_lane"},
      label: "atlas-river.lanes",
      set: {params: laneParams},
    })
    await lanes.compile(stage)
    const laneCall = {instances: 0, vertices: 4}

    const markQuads = instanced("atlas-river.marks", MARK_FLOATS, MAX_MARKS, ["at", "look"])
    const markParams = uniform("atlas-river.marks.params")
    const marks = draw(gpu, {
      shader,
      geometry: markQuads,
      blend: "premultiplied",
      vertices: 4,
      entry: {vertex: "vs_mark", fragment: "fs_mark"},
      label: "atlas-river.marks",
      set: {params: markParams},
    })
    await marks.compile(stage)
    const markCall = {instances: 0}

    const unsubscribe = stage.onResize(resized => {
      scale = resized.width / Math.max(1, canvas.clientWidth)
      width = resized.width
      height = resized.height
    })

    // A strip of 2 × (segments + 1) vertices a piece, enough for a smooth edge at this zoom.
    const vertices = (step: number, zoom: number) =>
      2 * (Math.min(MOST_SEGMENTS, Math.max(2, Math.ceil((step * zoom) / SEGMENT))) + 1)

    // One draw's numbers: everything shared, then its own base, step, strength, scales and segments.
    const write = (
      target: Buffer,
      base: number,
      step: number,
      strength: number,
      ko: number,
      kf: number,
      hover: number,
      segments: number,
    ) => {
      const view = seen!
      params[0] = width
      params[1] = height
      params[2] = scale
      params[3] = strength
      params[4] = base - view.hour
      params[5] = view.zoom
      params[6] = width / scale / 2
      params[7] = view.middle
      params[8] = ko
      params[9] = kf
      params[10] = view.open
      params[11] = view.lanes
      params[12] = view.region
      params[13] = view.lane
      params[14] = view.line
      params[15] = view.laneScale
      params[16] = step
      params[17] = segments
      params[18] = view.hoverBand
      params[19] = view.chosen
      params[20] = view.marks
      params[21] = view.cards
      params[22] = hover
      // The stripes move with the stream as it is dragged.
      params[23] = (((-view.hour * view.zoom) % 6) + 6) % 6
      params[24] = view.top
      params[26] = view.spread
      params.set(tones, 28)
      target.write(params)
    }

    // Made once, so a frame makes no closures of its own.
    const body = (pass: FramePass) => {
      for (const layer of layers) {
        if (layer.call.instances > 0) pass.draw(layer.draw, layer.call)
      }
      if (laneCall.instances > 0) pass.draw(lanes, laneCall)
      if (markCall.instances > 0) pass.draw(marks, markCall)
    }
    const record = (current: Frame) => current.pass(stage, body)

    return {
      tones(...colors) {
        colors.forEach((rgb, index) => {
          tones.set(rgb, index * 4)
          tones[index * 4 + 3] = 1
        })
      },
      pieces(layer, data, count) {
        counts[layer] = Math.min(count, MAX_PIECES)
        if (counts[layer] > 0) layers[layer].geometry.write(data.subarray(0, counts[layer] * PIECE_FLOATS))
      },
      lanes(data, count) {
        laneCount = Math.min(count, MAX_LANE_PIECES)
        if (laneCount > 0) lanePieces.write(data.subarray(0, laneCount * LANE_FLOATS))
      },
      marks(data, count) {
        markCount = Math.min(count, MAX_MARKS)
        if (markCount > 0) markQuads.write(data.subarray(0, markCount * MARK_FLOATS))
      },
      layer(layer, base, step, strength, ko, kf) {
        bases[layer] = base
        steps[layer] = step
        strengths[layer] = strength
        kos[layer] = ko
        kfs[layer] = kf
      },
      bases(lanesAt, marksAt, kf) {
        laneBase = lanesAt
        markBase = marksAt
        laneKf = kf
      },
      view(view) {
        seen = view
      },
      resize(nextWidth, nextHeight) {
        stage.resize([nextWidth, nextHeight])
      },
      step() {
        return false
      },
      present() {
        if (!seen) return
        for (let index = 0; index < layers.length; index++) {
          const layer = layers[index]
          layer.call.instances = strengths[index] > 0.001 ? counts[index] : 0
          if (layer.call.instances === 0) continue
          layer.call.vertices = vertices(steps[index], seen.zoom)
          const segments = layer.call.vertices / 2 - 1
          write(layer.params, bases[index], steps[index], strengths[index], kos[index], kfs[index], -1, segments)
        }
        // The lanes are drawn an hour a knot, as the hours are.
        laneCall.instances = seen.lanes > 0.001 ? laneCount : 0
        if (laneCall.instances > 0) {
          laneCall.vertices = vertices(1, seen.zoom)
          write(laneParams, laneBase, 1, 1, laneKf, laneKf, seen.hoverLane, laneCall.vertices / 2 - 1)
        }
        markCall.instances = seen.marks > 0.001 ? markCount : 0
        if (markCall.instances > 0) write(markParams, markBase, 1, 1, laneKf, laneKf, seen.hoverMark, 1)
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
