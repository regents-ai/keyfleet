/**
 * Draws the cards the homepage's Key card shuffles through when it is pointed at:
 * Keys of no fleet's deck, in the Interim Access Pass's own look. Each is a Key
 * the trait table could draw, kept to a black card, dark plain metal, a warm crown
 * and a plain satin foil, with its slot on the left, so every card fits where the
 * interim pass sits.
 * `window.shuffleCards(cards, size, frame)` draws each card at `size`, cuts
 * `frame.box` out of it and answers one PNG data URL per card at `frame.size`,
 * cut out of the studio (shuffle.mjs bundles the card shader that way).
 */

import {keyJob} from "../../platform/assets/js/key_card/paint"
import {startStills} from "../../platform/assets/js/key_card/stage"
import {drawKey, seedNumber, type Key} from "../../platform/assets/js/key_card/traits"

type Card = {seed: string}
type Size = [number, number]
type Frame = {box: [number, number, number, number]; size: Size}

declare global {
  interface Window {
    shuffleCards?: (cards: Card[], size: Size, frame: Frame) => Promise<string[]>
  }
}

/** The exteriors whose slot opens on the card's left edge, as the interim pass's does. */
const LEFT_SLOT = ["Signal", "Lantern", "Foundry", "Wyvern"]
/** The black card shells, nearest the interim pass's. */
const DARK_SHELL = ["Obsidian", "Carbon Weave"]
/** The dark metals for the key and fittings, as the interim pass's are black. */
const DARK_METAL = ["Graphite", "Meteorite"]
/** The warm crowns nearest the interim pass's Tangerine enamel. */
const WARM_CROWN = ["Copper", "Bronze", "Ruby Glass"]
/** The foil that leaves a black card black. */
const FOIL = "Satin"
/** The wear that keeps the metal dark and plain. */
const QUIET_PATINA = ["Mint", "Satin", "Hand-Rubbed", "Smoke"]
/** The words under KEYFLEET, as the interim pass prints them. */
const TOP_LINE = "ACCESS PASS"

const pick = (from: string[], n: number) => from[n % from.length]

/** The drawn pixels, cut to the frame and scaled to its size, as a PNG. */
const png = (pixels: Uint8Array, [w, h]: Size, {box: [x, y, bw, bh], size: [fw, fh]}: Frame): string => {
  const drawn = document.createElement("canvas")
  drawn.width = w
  drawn.height = h
  drawn.getContext("2d")!.putImageData(new ImageData(new Uint8ClampedArray(pixels), w, h), 0, 0)
  const frame = document.createElement("canvas")
  frame.width = fw
  frame.height = fh
  const g = frame.getContext("2d")!
  g.imageSmoothingQuality = "high"
  g.drawImage(drawn, x, y, bw, bh, 0, 0, fw, fh)
  return frame.toDataURL("image/png")
}

window.shuffleCards = async (cards, size, frame) => {
  const draw = await startStills(size)
  if (!draw) throw new Error("this browser has no WebGPU")
  const drawn: string[] = []
  for (const {seed} of cards) {
    const n = seedNumber(seed)
    const key: Key = {
      ...drawKey(seed),
      exterior: pick(LEFT_SLOT, n),
      shell: pick(DARK_SHELL, n >>> 8),
      metal: pick(DARK_METAL, n >>> 12),
      crown: pick(WARM_CROWN, n >>> 16),
      foil: FOIL,
      patina: pick(QUIET_PATINA, n >>> 24),
    }
    drawn.push(png(await draw(await keyJob(key, n, TOP_LINE)), size, frame))
  }
  return drawn
}

document.body.dataset.state = "ready"
