/**
 * The early-access page's key roller: "Roll an example Key" draws a random seed, draws the key's
 * eight traits from it the way a minted key gets them, and paints the key's card. Every trait lists
 * all sixteen values it could have landed on, with the drawn one marked, and its chance.
 */

import {keyJob} from "./key_card/paint"
import {startStage} from "./key_card/stage"
import {TIER_NAMES, TRAITS, drawKey, randomSeed, seedNumber, tierOf, weightOf, type Key} from "./key_card/traits"

/** A fleet holds 1,024 keys; the roller deals one of them from Classic fleet #1. */
const FLEET_KEYS = 1024
const topLine = (token: number): string => `CLASSIC #1 · NO. ${String(token).padStart(4, "0")}`

const el = <T extends HTMLElement>(tag: string, className: string, text = ""): T => {
  const node = document.createElement(tag) as T
  node.className = className
  node.textContent = text
  return node
}
/** A value's chance: its weight out of the 1,000 each trait shares, as a percentage. */
const odds = (weight: number): string => `${weight / 10}%`
const chip = (tier: number, text: string): HTMLElement => {
  const node = el("span", "roller__chip", text)
  node.dataset.tier = String(tier)
  return node
}

/** One row per trait: what this key got, and inside, every value the trait could have given. */
function traitRow(trait: (typeof TRAITS)[number], key: Key): HTMLDetailsElement {
  const weight = weightOf(trait, key)
  const tier = tierOf(weight)
  const row = el<HTMLDetailsElement>("details", "roller__trait")
  const summary = el("summary", "roller__trait-head")
  summary.append(
    el("span", "roller__trait-name", trait.name),
    el("span", "roller__trait-value", key[trait.id]),
    chip(tier, TIER_NAMES[tier]),
    el("span", "roller__odds", odds(weight)),
  )
  const values = el("ul", "roller__values")
  values.setAttribute("aria-label", `All ${trait.values.length} ${trait.name} values`)
  for (const value of trait.values) {
    const item = el("li", "roller__value")
    item.dataset.tier = String(tierOf(value.weight))
    if (value.name === key[trait.id]) item.setAttribute("aria-current", "true")
    item.append(el("span", "roller__value-name", value.name), el("span", "roller__odds", odds(value.weight)))
    values.append(item)
  }
  row.append(summary, values)
  return row
}

function status(token: number, key: Key): DocumentFragment {
  const [rarest] = TRAITS.map(t => ({trait: t, weight: weightOf(t, key)})).sort((a, b) => a.weight - b.weight)
  const line = document.createDocumentFragment()
  line.append(
    el("b", "", `Key No. ${token}.`),
    ` Rarest trait: ${rarest.trait.name}, `,
    el("b", "", key[rarest.trait.id]),
    ` (${odds(rarest.weight)}).`,
  )
  return line
}

function tally(key: Key): HTMLElement[] {
  const counts = TIER_NAMES.map(() => 0)
  for (const t of TRAITS) counts[tierOf(weightOf(t, key))]++
  return counts.flatMap((n, tier) => (n ? [chip(tier, `${n} ${TIER_NAMES[tier]}`)] : []))
}

async function mount(root: HTMLElement): Promise<void> {
  const canvas = root.querySelector<HTMLCanvasElement>("[data-roller-canvas]")!
  const stageBox = root.querySelector<HTMLElement>("[data-roller-stage]")!
  const button = root.querySelector<HTMLButtonElement>("[data-roller-roll]")!
  const statusLine = root.querySelector<HTMLElement>("[data-roller-status]")!
  const tallyBox = root.querySelector<HTMLElement>("[data-roller-tally]")!
  const rows = root.querySelector<HTMLElement>("[data-roller-traits]")!

  const stage = await startStage(canvas)
  if (!stage) stageBox.dataset.state = "no-gpu"

  let rolls = 0
  const roll = (): void => {
    const mine = ++rolls
    const seed = randomSeed()
    const token = 1 + Math.floor(Math.random() * FLEET_KEYS)
    const key = drawKey(seed)
    const open = new Set([...rows.querySelectorAll<HTMLDetailsElement>("details[open]")].map(d => d.dataset.trait))
    statusLine.replaceChildren(status(token, key))
    tallyBox.replaceChildren(...tally(key))
    rows.replaceChildren(
      ...TRAITS.map(t => {
        const row = traitRow(t, key)
        row.dataset.trait = t.id
        row.open = open.has(t.id)
        return row
      }),
    )
    if (!stage) return
    stageBox.dataset.state = "painting"
    void stage.show(() => keyJob(key, seedNumber(seed), topLine(token))).then(() => {
      if (mine === rolls) stageBox.dataset.state = "ready"
    })
  }

  button.addEventListener("click", roll)
  roll()
}

void mount(document.querySelector<HTMLElement>("[data-key-roller]")!)
