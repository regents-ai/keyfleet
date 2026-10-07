/**
 * Puts a key's card on a canvas with WebGPU. The card is a still picture, drawn again only when
 * the key changes or the canvas changes size.
 */

import {effect, frame, init, sampler, surface, texture, type Effect, type Gpu, type Surface, type Texture} from "vgpu"

import {CARD_WGSL} from "./shader"
import type {CardJob, Layers} from "./paint"

/** How close the camera frames the card. */
const STAGE_ZOOM = 0.84
const TEX_NAMES = ["extAlb", "extAux", "extMat", "keyAlb", "keyAux"] as const
type Textures = Record<(typeof TEX_NAMES)[number], Texture>

export type Stage = {
  /** Paints a card and shows it. When two overlap, the newer one wins. */
  show(make: () => Promise<CardJob>): Promise<void>
}

/** A stage on `canvas`, or nothing when the browser has no WebGPU. */
export async function startStage(canvas: HTMLCanvasElement): Promise<Stage | null> {
  let gpu: Gpu
  try {
    gpu = await init()
  } catch {
    return null
  }
  const out: Surface = surface(gpu, canvas, {dpr: [1, 1.75]})
  const samp = sampler(gpu, {minFilter: "linear", magFilter: "linear"})
  let fx: Effect | null = null
  let textures: Textures | null = null
  let ticket = 0

  const draw = (): void => {
    if (fx) frame(gpu, f => f.pass(out, fx!))
  }
  new ResizeObserver(draw).observe(canvas)

  const upload = (layer: Layers, bytes: Uint8Array<ArrayBuffer>): Texture => {
    const t = texture(gpu, {kind: "2d", size: [layer.w, layer.h], format: "rgba8unorm", usage: ["texture_binding", "copy_dst"]})
    gpu.gpu.queue.writeTexture({texture: t.gpu}, bytes, {bytesPerRow: layer.w * 4}, [layer.w, layer.h, 1])
    return t
  }

  return {
    async show(make) {
      const mine = ++ticket
      const {paint, uniforms} = await make()
      if (mine !== ticket) return
      const {exterior: e, key: k} = paint
      const next: Textures = {
        extAlb: upload(e, e.alb),
        extAux: upload(e, e.aux),
        extMat: upload(e, e.mat),
        keyAlb: upload(k, k.alb),
        keyAux: upload(k, k.aux),
      }
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
