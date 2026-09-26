import type {Page} from "@playwright/test"

// From the first paint the page records every inline transform or opacity any
// element takes, every number split into pieces to roll and whether the
// headline moved, so a test can ask what moved and whether it ended clean.
// The shell's page-change motion is recorded apart, as the regions it moved.
function recordMotion() {
  const moves = new Map<Element, string[]>()
  const rolled = new Set<string>()
  const pageMoves = new Set<string>()
  Object.assign(window, {__moves: moves, __rolled: rolled, __pageMoves: pageMoves})
  const watch = () =>
    new MutationObserver(records => {
      for (const record of records) {
        const el = record.target as Element
        if (record.type === "childList") {
          if (el.matches("[phx-hook=Counter]") && record.addedNodes.length > 0) rolled.add(el.id)
          continue
        }
        const style = el.getAttribute("style") ?? ""
        if (!/transform|opacity/.test(style)) continue
        // The copies of the page being left fade out whatever the reader asked for;
        // only the page arriving tells whether the change moved.
        if (el.closest("[data-motion-copy]")) continue
        if (el.matches("[data-motion-region], [data-motion-surface], [data-motion-background]")) {
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
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", watch)
  else watch()
}

type Recorded = {__moves: Map<Element, string[]>; __rolled: Set<string>; __pageMoves: Set<string>}

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

// Whether a page change moved the page arriving.
export const pageChangeMoved = (page: Page) => page.evaluate(() => (window as unknown as Recorded).__pageMoves.size > 0)

export const forget = (page: Page) =>
  page.evaluate(() => {
    ;(window as unknown as Recorded).__moves.clear()
    ;(window as unknown as Recorded).__rolled.clear()
    ;(window as unknown as Recorded).__pageMoves.clear()
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
// motion under test.
export async function pressRapidly(page: Page, selector: string, presses = 5, gap = 70) {
  const box = (await page.locator(selector).boundingBox())!
  for (let press = 0; press < presses; press++) {
    await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2)
    await page.waitForTimeout(gap)
  }
}
