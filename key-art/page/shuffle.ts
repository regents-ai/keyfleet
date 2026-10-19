/**
 * Draws the cards the homepage's Key card shuffles through when it is pointed at:
 * real Keys from the trait table, of no fleet's deck, drawn whole like the turning
 * cards lower on the page, key and all.
 * `window.shuffleCards(cards, size, scale)` draws each card at `size` and answers
 * one PNG data URL per card at `size` times `scale`, cut out of the studio
 * (shuffle.mjs bundles the card shader that way).
 */

import {keyJob} from "../../platform/assets/js/key_card/paint"
import {startStills} from "../../platform/assets/js/key_card/stage"
import {drawKey, seedNumber} from "../../platform/assets/js/key_card/traits"

type Card = {seed: string}
type Size = [number, number]

declare global {
  interface Window {
    shuffleCards?: (cards: Card[], size: Size, scale: number) => Promise<string[]>
  }
}

/** The words under KEYFLEET, as the turning cards print them. */
const TOP_LINE = "KEYFLEET"

/** The drawn pixels, scaled down, as a PNG. */
const png = (pixels: Uint8Array, [w, h]: Size, scale: number): string => {
  const drawn = document.createElement("canvas")
  drawn.width = w
  drawn.height = h
  drawn.getContext("2d")!.putImageData(new ImageData(new Uint8ClampedArray(pixels), w, h), 0, 0)
  const frame = document.createElement("canvas")
  frame.width = Math.round(w * scale)
  frame.height = Math.round(h * scale)
  const g = frame.getContext("2d")!
  g.imageSmoothingQuality = "high"
  g.drawImage(drawn, 0, 0, frame.width, frame.height)
  return frame.toDataURL("image/png")
}

window.shuffleCards = async (cards, size, scale) => {
  const draw = await startStills(size)
  if (!draw) throw new Error("this browser has no WebGPU")
  const drawn: string[] = []
  for (const {seed} of cards) {
    drawn.push(png(await draw(await keyJob(drawKey(seed), seedNumber(seed), TOP_LINE)), size, scale))
  }
  return drawn
}

document.body.dataset.state = "ready"
