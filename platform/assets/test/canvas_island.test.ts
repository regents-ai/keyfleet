import {afterEach, beforeEach, describe, expect, it, vi} from "vitest"

import {
  MAX_DEVICE_PIXEL_RATIO,
  MAX_DRAWING_BUFFER_PIXELS,
  STRAIN_WINDOW_FRAMES,
  createCanvasIsland,
  drawingBufferSize,
  type IslandRenderer,
} from "../js/canvas_island"

// The visitor never asked for a 4K backing store behind a headline.
describe("bounding the drawing buffer", () => {
  it("never exceeds the device pixel ratio ceiling", () => {
    expect(drawingBufferSize(400, 300, 3)).toEqual([
      400 * MAX_DEVICE_PIXEL_RATIO,
      300 * MAX_DEVICE_PIXEL_RATIO,
    ])
    expect(drawingBufferSize(400, 300, 0.5)).toEqual([400, 300])
  })

  it("never exceeds the pixel budget, at any shape", () => {
    for (const [width, height] of [
      [3840, 2160],
      [2560, 1080],
      [1200, 3000],
      [1600, 900],
      [390, 844],
    ] as const) {
      const [bufferWidth, bufferHeight] = drawingBufferSize(width, height, 3)

      expect(bufferWidth * bufferHeight, `${width}x${height}`).toBeLessThanOrEqual(
        MAX_DRAWING_BUFFER_PIXELS,
      )
      expect(bufferWidth / bufferHeight, `${width}x${height}`).toBeCloseTo(width / height, 1)
    }
  })

  it("always produces a drawable size", () => {
    expect(drawingBufferSize(0, 0, 1)).toEqual([1, 1])
  })
})

// An island on screen in a showing tab, its frames handed out on a clock the
// test turns: `gap(n)` is how long after frame n-1 frame n arrives.
const runIsland = async ({gap, frames}: {gap: (n: number) => number; frames: number}) => {
  let pending: FrameRequestCallback | undefined
  let held = 0
  const canvas = {getBoundingClientRect: () => ({width: 300, height: 200})}
  const root = {dataset: {}, querySelector: () => canvas} as unknown as HTMLElement
  const renderer: IslandRenderer = {
    resize() {},
    step: () => true,
    present() {},
    settled: async () => {},
    dispose() {},
  }

  createCanvasIsland(
    root,
    {
      requestFrame: callback => {
        pending = callback
        return 1
      },
      cancelFrame: () => {
        pending = undefined
      },
      devicePixelRatio: () => 1,
      motionQuery: () => ({matches: false, addEventListener() {}, removeEventListener() {}}),
      supportsWebGpu: () => true,
      loadRenderer: async () => renderer,
    },
    {
      canvasSelector: "canvas",
      readyFlag: "ready",
      browserLoad: async () => renderer,
      motionSensitive: false,
      continuous: true,
      interact: ({onStrain}) => {
        onStrain(() => {
          held += 1
        })
        return () => {}
      },
    },
  ).mount()

  let now = 0
  for (let n = 0; n < frames; n += 1) {
    // The renderer lands a few promise turns after the island asks for it.
    for (let turn = 0; turn < 4 && !pending; turn += 1) await Promise.resolve()
    const frame = pending
    pending = undefined
    now += gap(n)
    frame?.(now)
  }
  return held
}

beforeEach(() => {
  vi.stubGlobal("document", {hidden: false, addEventListener() {}, removeEventListener() {}})
  vi.stubGlobal(
    "ResizeObserver",
    class {
      observe() {}
      disconnect() {}
    },
  )
  vi.stubGlobal(
    "IntersectionObserver",
    class {
      constructor(private seen: (entries: {isIntersecting: boolean}[]) => void) {}
      observe() {
        this.seen([{isIntersecting: true}])
      }
      disconnect() {}
    },
  )
})

afterEach(() => {
  vi.unstubAllGlobals()
})

describe("a moving picture on a device short of frames", () => {
  // Safari's Low Power Mode and Chrome's Energy Saver hand a page 30 frames a second.
  it("is asked to hold still once, at 30 frames a second", async () => {
    expect(await runIsland({gap: () => 33, frames: STRAIN_WINDOW_FRAMES * 4})).toBe(1)
  })

  it("is asked to hold still on a device far behind", async () => {
    expect(await runIsland({gap: () => 150, frames: STRAIN_WINDOW_FRAMES * 2})).toBe(1)
  })

  it("keeps moving at 60 frames a second", async () => {
    expect(await runIsland({gap: () => 16.7, frames: STRAIN_WINDOW_FRAMES * 4})).toBe(0)
  })

  // A third of every stretch is slow, as while a page changes or a dialog loads.
  it("keeps moving through busy moments at 60 frames a second", async () => {
    const busy = (n: number) => (n % STRAIN_WINDOW_FRAMES < STRAIN_WINDOW_FRAMES / 3 ? 60 : 16.7)
    expect(await runIsland({gap: busy, frames: STRAIN_WINDOW_FRAMES * 4})).toBe(0)
  })
})
