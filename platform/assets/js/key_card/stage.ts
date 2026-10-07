/**
 * Puts a key's card on a canvas with WebGPU, or draws it once into an off-screen picture. On a
 * canvas the card is a still picture, drawn again only when the key changes or the canvas
 * changes size.
 */

import {effect, frame, init, sampler, surface, target, texture, type Effect, type Gpu, type Surface, type Texture} from "vgpu"

import {CARD_WGSL} from "./shader"
import type {CardJob, Layers} from "./paint"

/** How close the camera frames the card. */
const STAGE_ZOOM = 0.84
const TEX_NAMES = ["extAlb", "extAux", "extMat", "keyAlb", "keyAux"] as const
type Textures = Record<(typeof TEX_NAMES)[number], Texture>

const upload = (gpu: Gpu, layer: Layers, bytes: Uint8Array<ArrayBuffer>): Texture => {
  const t = texture(gpu, {kind: "2d", size: [layer.w, layer.h], format: "rgba8unorm", usage: ["texture_binding", "copy_dst"]})
  gpu.gpu.queue.writeTexture({texture: t.gpu}, bytes, {bytesPerRow: layer.w * 4}, [layer.w, layer.h, 1])
  return t
}

const uploadCard = (gpu: Gpu, {exterior: e, key: k}: CardJob["paint"]): Textures => ({
  extAlb: upload(gpu, e, e.alb),
  extAux: upload(gpu, e, e.aux),
  extMat: upload(gpu, e, e.mat),
  keyAlb: upload(gpu, k, k.alb),
  keyAux: upload(gpu, k, k.aux),
})

/** The page's GPU, or nothing when the browser has no WebGPU. */
const start = (): Promise<Gpu | null> => init().catch(() => null)

const linear = (gpu: Gpu) => sampler(gpu, {minFilter: "linear", magFilter: "linear"})

export type Stage = {
  /** Paints a card and shows it. When two overlap, the newer one wins. */
  show(make: () => Promise<CardJob>): Promise<void>
}

/** A stage on `canvas`, or nothing when the browser has no WebGPU. */
export async function startStage(canvas: HTMLCanvasElement): Promise<Stage | null> {
  const gpu = await start()
  if (!gpu) return null
  const out: Surface = surface(gpu, canvas, {dpr: [1, 1.75]})
  const samp = linear(gpu)
  let fx: Effect | null = null
  let textures: Textures | null = null
  let ticket = 0

  const draw = (): void => {
    if (fx) frame(gpu, f => f.pass(out, fx!))
  }
  new ResizeObserver(draw).observe(canvas)

  return {
    async show(make) {
      const mine = ++ticket
      const {paint, uniforms} = await make()
      if (mine !== ticket) return
      const next = uploadCard(gpu, paint)
      const old = textures
      textures = next
      const params = {res: out.size, zoom: STAGE_ZOOM, ...uniforms}
      if (fx) {
        fx.set({u: params, ...next})
      } else {
        const made = effect(gpu, CARD_WGSL, {label: "key-card", set: {u: params, ...next, samp}})
        await made.compile({colors: [out.format]})
        out.onResize(() => made.set({u: {res: out.size}}))
        fx = made
      }
      if (old) Object.values(old).forEach(t => t.destroy())
      draw()
    },
  }
}

/**
 * Draws key cards, one after another, into an off-screen picture `size` pixels across, keeping one
 * GPU for them all; or nothing when the browser has no WebGPU. Each draw answers the card's pixels,
 * four bytes (red, green, blue, alpha) each, row by row from the top.
 */
export async function startStills(size: readonly [number, number]): Promise<((job: CardJob) => Promise<Uint8Array>) | null> {
  const gpu = await start()
  if (!gpu) return null
  const out = target(gpu, {size, format: "rgba8unorm"})
  const samp = linear(gpu)
  let fx: Effect | null = null

  return async job => {
    const textures = uploadCard(gpu, job.paint)
    const params = {u: {res: out.size, zoom: STAGE_ZOOM, ...job.uniforms}, ...textures}
    if (fx) {
      fx.set(params)
    } else {
      const made = effect(gpu, CARD_WGSL, {label: "key-card", set: {...params, samp}})
      await made.compile({colors: [out.format]})
      fx = made
    }
    frame(gpu, f => f.pass(out, fx!))
    const pixels = await out.color.read({mipLevel: 0, region: "all"})
    Object.values(textures).forEach(t => t.destroy())
    return pixels
  }
}

/** Draws one key's card into an off-screen picture `size` pixels across, as `startStills` does. */
export async function drawStill(job: CardJob, size: readonly [number, number]): Promise<Uint8Array | null> {
  const draw = await startStills(size)
  return draw && draw(job)
}
