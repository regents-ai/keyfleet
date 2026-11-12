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

  // A small island may ask for more of a sharp screen than the default ceiling;
  // one that does not keeps to it, and the pixel budget holds either way.
  it("draws past the default ceiling only when an island asks for it", () => {
    expect(drawingBufferSize(300, 200, 3, 3)).toEqual([900, 600])
    expect(drawingBufferSize(300, 200, 3)).toEqual([450, 300])
    const [width, height] = drawingBufferSize(2000, 2000, 3, 3)
    expect(width * height).toBeLessThanOrEqual(MAX_DRAWING_BUFFER_PIXELS)
  })
})

const drawing: IslandRenderer = {
  resize() {},
  step: () => true,
  present() {},
  settled: async () => {},
  dispose() {},
}

// An island on screen in a showing tab, its frames handed out on a clock the
// test turns: `gap(n)` is how long after frame n-1 frame n arrives. The tab is
// hidden and shown again before frame `shownAgainAt`. It answers each time
// the picture was asked to hold still (true) or given another chance (false),
// and how often what steered the picture was let go.
const runIsland = async ({
  gap,
  frames,
  load = async () => drawing,
  shownAgainAt,
}: {
  gap: (n: number) => number
  frames: number
  load?: () => Promise<IslandRenderer>
  shownAgainAt?: number
}) => {
  let pending: FrameRequestCallback | undefined
  const held: boolean[] = []
  let released = 0
  const page = {hidden: false, onVisibility: () => {}}
  vi.stubGlobal("document", {
    get hidden() {
      return page.hidden
    },
    addEventListener: (_type: string, listener: () => void) => {
      page.onVisibility = listener
    },
    removeEventListener() {},
  })
  const canvas = {getBoundingClientRect: () => ({width: 300, height: 200})}
  const root = {dataset: {}, querySelector: () => canvas} as unknown as HTMLElement

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
      loadRenderer: load,
    },
    {
      canvasSelector: "canvas",
      readyFlag: "ready",
      browserLoad: load,
      motionSensitive: false,
      continuous: true,
      interact: ({onStrain}) => {
        onStrain(strained => held.push(strained))
        return () => {
          released += 1
        }
      },
    },
  ).mount()

  let now = 0
  for (let n = 0; n < frames; n += 1) {
    if (n === shownAgainAt) {
      page.hidden = true
      page.onVisibility()
      page.hidden = false
      page.onVisibility()
    }
    // The renderer lands a few promise turns after the island asks for it.
    for (let turn = 0; turn < 4 && !pending; turn += 1) await Promise.resolve()
    const frame = pending
    pending = undefined
    now += gap(n)
    frame?.(now)
  }
  return {held, released}
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
    expect((await runIsland({gap: () => 33, frames: STRAIN_WINDOW_FRAMES * 4})).held).toEqual([true])
  })

  it("is asked to hold still on a device far behind", async () => {
    expect((await runIsland({gap: () => 150, frames: STRAIN_WINDOW_FRAMES * 2})).held).toEqual([true])
  })

  it("keeps moving at 60 frames a second", async () => {
    expect((await runIsland({gap: () => 16.7, frames: STRAIN_WINDOW_FRAMES * 4})).held).toEqual([])
  })

  // A third of every stretch is slow, as while a page changes or a dialog loads.
  it("keeps moving through busy moments at 60 frames a second", async () => {
    const busy = (n: number) => (n % STRAIN_WINDOW_FRAMES < STRAIN_WINDOW_FRAMES / 3 ? 60 : 16.7)
    expect((await runIsland({gap: busy, frames: STRAIN_WINDOW_FRAMES * 4})).held).toEqual([])
  })

  // R-20261019-strained-sea-recovers: a sea asked to hold still stayed still
  // until the page was opened again.
  it("is given another chance when the tab is shown again, and keeps moving once its frames are back", async () => {
    const plugged = STRAIN_WINDOW_FRAMES * 2
    const gap = (n: number) => (n < plugged ? 33 : 16.7)
    const {held} = await runIsland({gap, frames: STRAIN_WINDOW_FRAMES * 5, shownAgainAt: plugged})
    expect(held).toEqual([true, false])
  })

  it("is asked to hold still again when the tab comes back to a device still short of frames", async () => {
    const shown = STRAIN_WINDOW_FRAMES * 2
    const {held} = await runIsland({gap: () => 33, frames: STRAIN_WINDOW_FRAMES * 4, shownAgainAt: shown})
    expect(held).toEqual([true, false, true])
  })

  it("is never given another chance it does not need", async () => {
    const {held} = await runIsland({gap: () => 16.7, frames: STRAIN_WINDOW_FRAMES * 3, shownAgainAt: 100})
    expect(held).toEqual([])
  })
})

// R-20261019-failed-start-lets-go: a field whose GPU never started kept every
// mouse listener it had added.
describe("an island whose GPU does not start", () => {
  it("lets go of what steers the picture, once", async () => {
    const {released} = await runIsland({
      gap: () => 16.7,
      frames: 8,
      load: () => Promise.reject(new Error("no device")),
    })
    expect(released).toBe(1)
  })

  it("keeps hold of it while the picture draws", async () => {
    expect((await runIsland({gap: () => 16.7, frames: 8})).released).toBe(0)
  })
})
