import type {Page} from "@playwright/test"

// From the first paint the page records every inline transform or opacity any
// element takes, every number split into pieces to roll and whether the
// headline moved, so a test can ask what moved and whether it ended clean.
// The shell's page-change motion, the page arriving, is recorded apart.
// Each time a number or the headline splits, it records whether every piece
// sits in a box clipped by its class (`.split-clip`) rather than by a style of
// its own, which a policy refusing style attributes would refuse.
function recordMotion() {
  const moves = new Map<Element, string[]>()
  const rolled = new Set<string>()
  const pageMoves = new Set<string>()
  const clipped = new Map<string, boolean>()
  Object.assign(window, {__moves: moves, __rolled: rolled, __pageMoves: pageMoves, __clipped: clipped})
  const clippedByClass = (el: Element) =>
    el.matches(".split-clip") && (el as HTMLElement).style.overflow === "" && getComputedStyle(el).overflow === "clip"
  const piece = "[data-word], [data-char], :has(> [data-word], > [data-char])"
  const noteSplit = (id: string, added: NodeList) => {
    const pieces = [...added].filter(node => node instanceof Element && node.matches(piece)) as Element[]
    if (pieces.length > 0) clipped.set(id, (clipped.get(id) ?? true) && pieces.every(clippedByClass))
  }
  // A page the server draws once splits its headline before this starts
  // watching, so the pieces are read as they stand.
  const watch = () => {
    const headline = document.querySelector("main h1")
    if (headline) noteSplit("headline", headline.childNodes)
    new MutationObserver(records => {
      for (const record of records) {
        const el = record.target as Element
        if (record.type === "childList") {
          if (el.matches("[data-count]") && record.addedNodes.length > 0) {
            const id = el.closest("[phx-hook=MotionCount]")!.id
            rolled.add(id)
            noteSplit(id, record.addedNodes)
          }
          if (el.closest("main h1")) noteSplit("headline", record.addedNodes)
          continue
        }
        const style = el.getAttribute("style") ?? ""
        if (!/transform|opacity/.test(style)) continue
        if (el.id === "route-content") {
          pageMoves.add(el.id)
          continue
        }
        if (el.closest("main h1")) rolled.add("headline")
        moves.set(el, [...(moves.get(el) ?? []), style])
      }
    }).observe(document.documentElement, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ["style"],
    })
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", watch)
  else watch()
}

type Recorded = {
  __moves: Map<Element, string[]>
  __rolled: Set<string>
  __pageMoves: Set<string>
  __clipped: Map<string, boolean>
}

export const watchMotion = (page: Page) => page.addInitScript(recordMotion)

export const moved = (page: Page, selector: string) =>
  page.evaluate(
    selector => [...document.querySelectorAll(selector)].some(el => (window as unknown as Recorded).__moves.has(el)),
    selector,
  )

export const movedCount = (page: Page, selector: string) =>
  page.evaluate(
    selector => [...document.querySelectorAll(selector)].filter(el => (window as unknown as Recorded).__moves.has(el)).length,
    selector,
  )

export const anythingMoved = (page: Page) =>
  page.evaluate(() => (window as unknown as Recorded).__moves.size + (window as unknown as Recorded).__rolled.size > 0)

export const rolled = (page: Page, id: string) => page.evaluate(id => (window as unknown as Recorded).__rolled.has(id), id)

// Whether the number with this id, or "headline", split into pieces that each
// sat in a box clipped by class; undefined if it never split.
export const clippedByClass = (page: Page, id: string) =>
  page.evaluate(id => (window as unknown as Recorded).__clipped.get(id), id)

// Whether a page change moved the page arriving.
export const pageChangeMoved = (page: Page) => page.evaluate(() => (window as unknown as Recorded).__pageMoves.size > 0)

export const forget = (page: Page) =>
  page.evaluate(() => {
    ;(window as unknown as Recorded).__moves.clear()
    ;(window as unknown as Recorded).__rolled.clear()
    ;(window as unknown as Recorded).__pageMoves.clear()
    ;(window as unknown as Recorded).__clipped.clear()
  })

// What still carries an inline transform or opacity after moving; empty once
// everything has settled.
export const leftovers = (page: Page) =>
  page.evaluate(() =>
    [...(window as unknown as Recorded).__moves.keys()]
      .filter(el => el.isConnected && /transform|opacity/.test(el.getAttribute("style") ?? ""))
      .map(el => `${el.tagName.toLowerCase()}#${el.id}`),
  )

// Presses the control again and again with a pointer, each press landing while
// the last one's motion is still playing. The mouse goes straight to the
// control's middle, since waiting for it to hold still would wait out the
// motion under test. A control below the fold is scrolled to first, as a
// reader would.
export async function pressRapidly(page: Page, selector: string, presses = 5, gap = 70) {
  await page.locator(selector).scrollIntoViewIfNeeded()
  const box = (await page.locator(selector).boundingBox())!
  for (let press = 0; press < presses; press++) {
    await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2)
    await page.waitForTimeout(gap)
  }
}
