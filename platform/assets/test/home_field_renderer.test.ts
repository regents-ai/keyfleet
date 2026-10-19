import {expect, it, vi} from "vitest"

// R-20261019-field-build-not-lost: a hex field whose shader failed to build
// reported the device it disposed as lost, so the island asked for a new one
// three times over.

// A device that, like vgpu's, reports itself lost once it is disposed, and a
// surface that cannot be made on it.
const device = vi.hoisted(() => {
  let lose = () => {}
  return {
    disposed: 0,
    gpu: {
      lost: new Promise<void>(resolve => {
        lose = resolve
      }),
      dispose() {
        device.disposed += 1
        lose()
      },
    },
  }
})

vi.mock("vgpu", () => ({
  init: async () => device.gpu,
  surface: () => {
    throw new Error("VGPU-SURFACE: the canvas has no context")
  },
  effect: () => ({}),
  frame: () => {},
}))
vi.mock("@vgpu/wgsl/prepare", () => ({prepareShader: (source: string) => source}))

import {createFieldRenderer} from "../js/home_hero/renderer"

it("a field that fails to build disposes its device without reporting it lost", async () => {
  const lost = vi.fn()

  await expect(createFieldRenderer({} as HTMLCanvasElement, [300, 200], lost, 40)).rejects.toThrow(
    "VGPU-SURFACE",
  )
  // The loss settles a few promise turns after the dispose.
  for (let turn = 0; turn < 4; turn += 1) await Promise.resolve()

  expect(device.disposed).toBe(1)
  expect(lost).not.toHaveBeenCalled()
})
