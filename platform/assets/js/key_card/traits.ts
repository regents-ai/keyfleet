/**
 * A key's traits, drawn from its seed and the trait table by the rule in
 * `contracts/README.md`, exactly as `Keyfleet.Traits.draw/2` draws them.
 *
 * The table is the file the release ships in `priv/trait_tables`, named by its
 * fingerprint, so the page and the site read the same bytes.
 */

import {keccak_256} from "@noble/hashes/sha3"
import {hexToBytes} from "@noble/hashes/utils"

import table from "../../../priv/trait_tables/0x154aa5ac0169cf32835eee2e49c284f8626122e17ed66a82c7629257e63be3e8.json"

/** The table's fingerprint: keccak256 of the file, byte for byte. */
export const TABLE_HASH = "0x154aa5ac0169cf32835eee2e49c284f8626122e17ed66a82c7629257e63be3e8"

export type TraitId = "exterior" | "metal" | "shell" | "foil" | "emblem" | "rim" | "patina" | "crown"
export type TraitValue = {readonly name: string; readonly weight: number}
export type Trait = {readonly id: TraitId; readonly name: string; readonly values: readonly TraitValue[]}
/** One value per trait, by trait id. */
export type Key = Readonly<Record<TraitId, string>>

const IDS: Readonly<Record<string, TraitId>> = {
  "Exterior Design": "exterior",
  "Key Material": "metal",
  "Card Shell": "shell",
  Foil: "foil",
  Emblem: "emblem",
  Rim: "rim",
  Patina: "patina",
  "Regents Crown": "crown",
}

/** Every trait, in the order the draw takes them. Each trait's weights add up to 1,000. */
export const TRAITS: readonly Trait[] = table.traits.map(t => ({id: IDS[t.name], name: t.name, values: t.values}))

export const TIER_NAMES = ["Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic"] as const
/** The rarity a weight out of 1,000 belongs to, 0 for Common up to 5 for Mythic. */
export const tierOf = (weight: number): number =>
  weight >= 100 ? 0 : weight >= 60 ? 1 : weight >= 25 ? 2 : weight >= 7 ? 3 : weight >= 2 ? 4 : 5

export const traitOf = (id: TraitId): Trait => TRAITS.find(t => t.id === id)!
export const weightOf = (trait: Trait, key: Key): number => trait.values.find(v => v.name === key[trait.id])!.weight
/** Where a value sits in its trait's list, which is how the shader names patinas and foils. */
export const indexOf = (id: TraitId, name: string): number => traitOf(id).values.findIndex(v => v.name === name)

/**
 * Trait `i`, counting from 0, takes word `i` = keccak256(abi.encode(seed, i)). With `u` the word's
 * top 32 bits, the value is the first whose running weight exceeds floor(u * 1000 / 2^32).
 */
export function drawKey(seedHex: string): Key {
  const seed = hexToBytes(seedHex.slice(2))
  const key = {} as Record<TraitId, string>
  TRAITS.forEach((trait, i) => {
    const word = new Uint8Array(64)
    word.set(seed, 0)
    let x = i
    for (let k = 63; k >= 32 && x > 0; k--) {
      word[k] = x & 255
      x = Math.floor(x / 256)
    }
    const h = keccak_256(word)
    const u = h[0] * 16777216 + h[1] * 65536 + h[2] * 256 + h[3]
    const r = Math.floor((u * 1000) / 4294967296)
    let running = 0
    key[trait.id] = trait.values.find(v => (running += v.weight) > r)!.name
  })
  return key
}

export function randomSeed(): string {
  const bytes = new Uint8Array(32)
  crypto.getRandomValues(bytes)
  return "0x" + [...bytes].map(b => b.toString(16).padStart(2, "0")).join("")
}

/** The last 32 bits of the seed, which seed the small random choices in the painting. */
export const seedNumber = (seedHex: string): number => parseInt(seedHex.slice(-8), 16)
