/**
 * Draws a fleet's Worldline with WebGPU through vgpu: the trails as ribbons,
 * one instance per stretch between two events, and every event's mark as a
 * point, one instance each. The events reach the GPU only when they change;
 * each frame sends only where the picture stands, its orbit and what is in
 * focus, so thousands of events cost one buffer write when they arrive and
 * nothing after.
 */
import {prepareShader} from "@vgpu/wgsl/prepare"
import {draw, frame, geometry, init, surface} from "vgpu"

import {pointsWgsl, trailsWgsl} from "./shader"
import {MAX_EVENTS, POINT_FLOATS, SEGMENT_FLOATS} from "./trails"

type Rgb = readonly [number, number, number]

/** The colours, in the shader's palette order (`TONE` in trails.ts). */
export type Tones = {
  readonly line: Rgb
  readonly workspace: Rgb
  readonly code: Rgb
  readonly notebooks: Rgb
  readonly chat: Rgb
  readonly opened: Rgb
  readonly closed: Rgb
  readonly poll: Rgb
  /** How strong the glow is, and how faint a trail's far side, 0..1. */
  readonly glow: number
  readonly far: number
}

/** Where the picture stands this frame, in seconds from the anchor. */
export type Frame = {
  readonly now: number
  readonly left: number
  /** Seconds across one CSS pixel. */
  readonly perPx: number
  readonly orbit: number
  readonly revealed: number
  readonly focus: number
  readonly emphasis: number
  readonly arrivedFrom: number
  readonly arrival: number
}

export type WorldlineRenderer = {
  resize(width: number, height: number): void
  tones(tones: Tones): void
  /**
   * Every stretch of trail and every mark, as `pack` in trails.ts writes them
   * for at most `MAX_EVENTS` events.
   */
  load(segments: Float32Array<ArrayBuffer>, points: Float32Array<ArrayBuffer>): void
  present(at: Frame): void
  settled(): Promise<void>
  dispose(): void
}

const SEGMENTS = 40
// Every event has a stretch and every trail one more on to now, so twice the
// events and the line hold them all; every event has a mark, and the head one.
const SEGMENT_ROOM = MAX_EVENTS * 2 + 1
const POINT_ROOM = MAX_EVENTS + 1

const instance = (data: Float32Array<ArrayBuffer>) => [
  {
    stepMode: "instance" as const,
    data,
    attributes: {
      a: {format: "float32x4" as const, location: 0},
      b: {format: "float32x4" as const, location: 1},
      c: {format: "float32x4" as const, location: 2},
    },
  },
]

export async function createWorldlineRenderer(
  canvas: HTMLCanvasElement,
  size: readonly [number, number],
  onDeviceLost: () => void,
): Promise<WorldlineRenderer> {
  // Device pixels per CSS pixel, which the island may have capped below the
  // screen's own.
  let scale = 1
  let pixels: readonly [number, number] = [size[0], size[1]]
  let segmentCount = 0
  let pointCount = 0

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
      label: "worldline",
    })
    stage.resize([size[0], size[1]])
    const strips = geometry(gpu, {
      topology: "triangle-strip",
      label: "worldline.trails",
      buffers: instance(new Float32Array(SEGMENT_ROOM * SEGMENT_FLOATS)),
    })
    const quads = geometry(gpu, {
      topology: "triangle-strip",
      label: "worldline.marks",
      buffers: instance(new Float32Array(POINT_ROOM * POINT_FLOATS)),
    })
    const params = {
      size: [size[0], size[1], 1, 0],
      view: [0, 1, 0, 0],
      focus: [-1, 0, 0, 0],
      mood: [0.3, 0.4, 0, 0],
      line: [1, 1, 1, 1],
      workspace: [1, 1, 1, 1],
      code: [1, 1, 1, 1],
      notebooks: [1, 1, 1, 1],
      chat: [1, 1, 1, 1],
      opened: [1, 1, 1, 1],
      closed: [1, 1, 1, 1],
      poll: [1, 1, 1, 1],
    }
    const trails = draw(gpu, {
      shader: prepareShader(trailsWgsl, "worldline-trails.wgsl"),
      geometry: strips,
      blend: "premultiplied",
      vertices: (SEGMENTS + 1) * 2,
      label: "worldline.trails.pass",
      set: {params},
    })
    const marks = draw(gpu, {
      shader: prepareShader(pointsWgsl, "worldline-marks.wgsl"),
      geometry: quads,
      blend: "premultiplied",
      vertices: 4,
      label: "worldline.marks.pass",
      set: {params},
    })
    await Promise.all([trails.compile(stage), marks.compile(stage)])
    const unsubscribe = stage.onResize(({width, height}) => {
      scale = width / Math.max(1, canvas.clientWidth)
      pixels = [width, height]
    })

    const set = (values: Partial<typeof params>) => {
      trails.set({params: values})
      marks.set({params: values})
    }

    return {
      resize(width, height) {
        stage.resize([width, height])
      },
      tones(tones) {
        set({
          mood: [tones.glow, tones.far, 0, 0],
          line: [...tones.line, 1],
          workspace: [...tones.workspace, 1],
          code: [...tones.code, 1],
          notebooks: [...tones.notebooks, 1],
          chat: [...tones.chat, 1],
          opened: [...tones.opened, 1],
          closed: [...tones.closed, 1],
          poll: [...tones.poll, 1],
        })
      },
      load(segments, points) {
        segmentCount = segments.length / SEGMENT_FLOATS
        pointCount = points.length / POINT_FLOATS
        strips.write(segments)
        quads.write(points)
      },
      present(at) {
        set({
          size: [pixels[0], pixels[1], scale, at.now],
          view: [at.left, at.perPx / scale, at.orbit, at.revealed],
          focus: [at.focus, at.emphasis, at.arrivedFrom, at.arrival],
        })
        frame(gpu, current =>
          current.pass(stage, pass => {
            if (segmentCount > 0) pass.draw(trails, {instances: segmentCount})
            if (pointCount > 0) pass.draw(marks, {instances: pointCount})
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
        quads.destroy()
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
