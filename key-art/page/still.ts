/**
 * Draws one key's card for its still picture. The page's address names the key:
 * `#seed=0x…&top=<top line>&table=<trait table fingerprint>`. When the card is drawn,
 * `body[data-state]` becomes `done` and `window.stillPicture` holds it as a PNG data URL;
 * when it cannot be drawn, `refused` with the reason in `data-reason`.
 */

import {keyJob} from "../../platform/assets/js/key_card/paint"
import {drawStill} from "../../platform/assets/js/key_card/stage"
import {TABLE_HASH, drawKey, seedNumber} from "../../platform/assets/js/key_card/traits"

declare global {
  interface Window {
    stillPicture?: string
  }
}

/** The picture's size in pixels, as the Key Lab saved it. */
const SIZE = [767, 959] as const

const finish = (state: "done" | "refused", reason = ""): void => {
  document.body.dataset.reason = reason
  document.body.dataset.state = state
}

/** The pixels as a PNG data URL, through a 2D canvas. */
function png(pixels: Uint8Array): string {
  const [w, h] = SIZE
  const canvas = document.createElement("canvas")
  canvas.width = w
  canvas.height = h
  canvas.getContext("2d")!.putImageData(new ImageData(new Uint8ClampedArray(pixels), w, h), 0, 0)
  return canvas.toDataURL("image/png")
}

async function draw(): Promise<void> {
  const asked = new URLSearchParams(location.hash.slice(1))
  const seed = asked.get("seed") ?? ""
  const top = asked.get("top") ?? ""
  if (asked.get("table") !== TABLE_HASH) return finish("refused", `this page draws from the trait table ${TABLE_HASH}`)
  if (!/^0x[0-9a-f]{64}$/.test(seed)) return finish("refused", "the seed is not 32 bytes of lowercase hex")
  if (!top) return finish("refused", "the card's top line is missing")

  const pixels = await drawStill(await keyJob(drawKey(seed), seedNumber(seed), top), SIZE)
  if (!pixels) return finish("refused", "this browser has no WebGPU")
  window.stillPicture = png(pixels)
  finish("done")
}

void draw()
