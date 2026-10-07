/**
 * The local deck view: each deck's cards in a grid, drawn one at a time as they come near the
 * screen, and any card opened large with its eight traits.
 */

import {keyJob} from "../key_card/paint"
import {startStage, startStills, type Stage} from "../key_card/stage"
import {TIER_NAMES, TRAITS, drawKey, seedNumber, tierOf, weightOf, type Key} from "../key_card/traits"

/** Each small card is drawn at twice its shown size, then shrunk once more for a clean edge. */
const DRAWN: [number, number] = [384, 480]
const SHOWN: [number, number] = [192, 240]

type Card = {fleet: string; number: number; seed: string; key: Key; tier: number}
type HookContext = {el: HTMLElement}

const el = <T extends HTMLElement>(tag: string, className: string, text = ""): T => {
  const node = document.createElement(tag) as T
  node.className = className
  node.textContent = text
  return node
}
const topLine = (card: Card): string => `${card.fleet} · CARD ${String(card.number).padStart(4, "0")}`
const rarest = (key: Key): number => Math.max(...TRAITS.map(t => tierOf(weightOf(t, key))))
const odds = (weight: number): string => `${weight / 10}%`

function deckCards(section: HTMLElement): Card[] {
  const fleet = section.dataset.fleet!
  return (JSON.parse(section.dataset.cards!) as string[]).map((seed, number) => {
    const key = drawKey(seed)
    return {fleet, number, seed, key, tier: rarest(key)}
  })
}

function tally(cards: Card[]): string {
  const counts = TIER_NAMES.map(() => 0)
  for (const card of cards) counts[card.tier]++
  const parts = TIER_NAMES.map((name, tier) => `${name} ${counts[tier]}`).reverse()
  return `Rarest trait on each card: ${parts.join(" · ")}`
}

function cell(card: Card): HTMLButtonElement {
  const button = el<HTMLButtonElement>("button", "deck__card")
  button.type = "button"
  button.dataset.tier = String(card.tier)
  button.setAttribute("aria-label", `Card ${card.number}, rarest trait ${TIER_NAMES[card.tier]}`)
  const canvas = el<HTMLCanvasElement>("canvas", "deck__picture")
  ;[canvas.width, canvas.height] = SHOWN
  button.append(canvas, el("span", "deck__number", String(card.number)))
  return button
}

function traitRows(key: Key): HTMLLIElement[] {
  return TRAITS.map(trait => {
    const weight = weightOf(trait, key)
    const tier = tierOf(weight)
    const row = el<HTMLLIElement>("li", "deck-zoom__trait")
    row.dataset.tier = String(tier)
    row.append(
      el("span", "deck-zoom__trait-name", trait.name),
      el("span", "deck-zoom__trait-value", key[trait.id]),
      el("span", "deck-zoom__tier", TIER_NAMES[tier]),
      el("span", "deck-zoom__odds", odds(weight)),
    )
    return row
  })
}

export const DeckViewer = {
  async mounted(this: HookContext) {
    const root = this.el
    const decks = [...root.querySelectorAll<HTMLElement>("[data-deck]")].map(section => {
      const cards = deckCards(section)
      section.querySelector("[data-deck-tally]")!.textContent = tally(cards)
      return {section, cards}
    })
    const cards = new Map<HTMLElement, {card: Card; deck: Card[]}>()
    for (const {section, cards: deck} of decks) {
      const grid = section.querySelector<HTMLElement>("[data-deck-grid]")!
      grid.append(
        ...deck.map(card => {
          const button = cell(card)
          cards.set(button, {card, deck})
          return button
        }),
      )
    }

    const zoom = root.querySelector<HTMLDialogElement>("[data-deck-zoom]")!
    const zoomCanvas = zoom.querySelector<HTMLCanvasElement>("[data-deck-zoom-canvas]")!
    const zoomTitle = zoom.querySelector<HTMLElement>("[data-deck-zoom-title]")!
    const zoomTraits = zoom.querySelector<HTMLElement>("[data-deck-zoom-traits]")!
    let stage: Promise<Stage | null> | null = null
    let open: {card: Card; deck: Card[]} | null = null

    const show = (card: Card, deck: Card[]): void => {
      open = {card, deck}
      zoomTitle.textContent = `${card.fleet} · Card ${card.number}`
      zoomTraits.replaceChildren(...traitRows(card.key))
      if (!zoom.open) zoom.showModal()
      stage ??= startStage(zoomCanvas)
      void stage.then(s => s?.show(() => keyJob(card.key, seedNumber(card.seed), topLine(card))))
    }
    const move = (step: number): void => {
      if (!open) return
      const next = open.deck[open.card.number + step]
      if (next) show(next, open.deck)
    }

    root.addEventListener("click", event => {
      const target = event.target as HTMLElement
      const button = target.closest<HTMLElement>(".deck__card")
      const picked = button && cards.get(button)
      if (picked) show(picked.card, picked.deck)
      const step = target.closest<HTMLElement>("[data-deck-zoom-move]")?.dataset.deckZoomMove
      if (step) move(Number(step))
      if (target.closest("[data-deck-zoom-close]") || target === zoom) zoom.close()
    })
    zoom.addEventListener("keydown", event => {
      if (event.key === "ArrowLeft") move(-1)
      if (event.key === "ArrowRight") move(1)
    })
    zoom.addEventListener("close", () => {
      open = null
    })

    const draw = await startStills(DRAWN)
    if (!draw) {
      root.querySelector<HTMLElement>("[data-deck-no-gpu]")!.hidden = false
      return
    }

    // Cards near the screen wait their turn here, in the order they came near; one draws at a time.
    const near = new Set<HTMLElement>()
    let drawing = false
    const drawNear = async (): Promise<void> => {
      if (drawing) return
      drawing = true
      while (near.size) {
        const button: HTMLElement = near.values().next().value!
        near.delete(button)
        watch.unobserve(button)
        const {card} = cards.get(button)!
        const pixels = await draw(await keyJob(card.key, seedNumber(card.seed), topLine(card)))
        const picture = new ImageData(new Uint8ClampedArray(pixels), ...DRAWN)
        const [w, h] = SHOWN
        const shrunk = await createImageBitmap(picture, {resizeWidth: w, resizeHeight: h, resizeQuality: "high"})
        button.querySelector<HTMLCanvasElement>("canvas")!.getContext("2d")!.drawImage(shrunk, 0, 0)
        shrunk.close()
      }
      drawing = false
    }
    const watch = new IntersectionObserver(
      entries => {
        for (const entry of entries) {
          const button = entry.target as HTMLElement
          if (entry.isIntersecting) near.add(button)
          else near.delete(button)
        }
        void drawNear()
      },
      {rootMargin: "400px 0px"},
    )
    cards.forEach((_, button) => watch.observe(button))
  },
}
