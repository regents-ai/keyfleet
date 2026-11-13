import {expect, test, type Page} from "@playwright/test"
import {moveKey, prepareFleet, sellKey} from "./support/fleet_chain"
import {
  anythingMoved,
  clippedByClass,
  forget,
  inkSpots,
  leftovers,
  moved,
  pressRapidly,
  rolled,
  watchMotion,
} from "./support/motion"

// A fleet page's motion: presses squish and dialogs rise only for a pointer,
// the tabs' mark glides to a tab a pointer picks, a sale rolls its numbers and
// its line joins the hall's feed, and everything ends clean. Nothing moves for a reader
// who asked for less motion.
const fleet = "fleet_tech_classic"
// A fleet no walk talks in, so its feed holds only the lines this walk makes.
const quiet = "fleet_tech_accelerant"
const buyer = "0x2222222222222222222222222222222222222222"
const heir = "0x3333333333333333333333333333333333333333"

test.beforeAll(() => {
  prepareFleet(fleet)
  prepareFleet(quiet)
})

async function openFleet(page: Page, path = "/classic/1") {
  await watchMotion(page)
  await page.goto(path)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  await forget(page)
}

// Whether the tabs' mark lies along the bottom of this tab.
const markUnder = (page: Page, tab: string) =>
  page.evaluate(tab => {
    const mark = document.querySelector("#fleet-tabs [data-ink]")!.getBoundingClientRect()
    const under = document.querySelector(tab)!.getBoundingClientRect()
    return [mark.left - under.left, mark.width - under.width, mark.bottom - under.bottom].every(gap => Math.abs(gap) < 1)
  }, tab)

const plainNumber = (page: Page, id: string) =>
  page.locator(`#${id} [data-count]`).evaluate(el => (el.children.length === 0 ? el.textContent!.trim() : null))

test("a pointer press squishes its control and rises a dialog, all ending clean", async ({page}) => {
  await openFleet(page)

  await page.locator("#fleet-show-chat").click()
  await expect(page.locator("#fleet-show-chat")).toHaveAttribute("aria-pressed", "true")
  await expect.poll(() => moved(page, "#fleet-show-chat")).toBe(true)

  await page.locator("#fleet-get-key").click()
  await expect(page.locator("dialog#buy-key")).toBeVisible()
  // Its Key cards turn while they are on screen (KeyCards).
  await expect(page.locator("#buy-key-cards")).toHaveAttribute("data-cards-turning")
  await expect.poll(() => moved(page, "#fleet-get-key")).toBe(true)
  await expect.poll(() => moved(page, "dialog#buy-key")).toBe(true)
  await page.keyboard.press("Escape")
  await expect(page.locator("dialog#buy-key")).toHaveCount(0)

  await expect.poll(() => leftovers(page)).toEqual([])
})

test("a keyboard press picks a channel and opens panels and dialogs at once, with no squish", async ({page}) => {
  await openFleet(page)

  await page.locator("#fleet-show-chat").focus()
  await page.keyboard.press("Enter")
  await expect(page.locator("#fleet-show-chat")).toHaveAttribute("aria-pressed", "true")
  await page.locator("#fleet-get-key").focus()
  await page.keyboard.press("Enter")
  await expect(page.locator("dialog#buy-key")).toBeVisible()
  await page.keyboard.press("Escape")
  await page.waitForTimeout(600)

  expect(await anythingMoved(page)).toBe(false)
})

test("the mark under the fleet's tabs glides to a tab picked with a pointer and is simply there for the keyboard", async ({
  page,
}) => {
  await openFleet(page)
  await expect.poll(() => markUnder(page, "#fleet-tab-hall")).toBe(true)
  await expect(page.locator("#fleet-tabs [data-ink]")).toBeVisible()
  await forget(page)

  await page.locator("#fleet-tab-proposals").click()
  await expect(page.locator("#fleet-tab-proposals")).toHaveAttribute("aria-current", "page")
  await expect.poll(() => markUnder(page, "#fleet-tab-proposals")).toBe(true)
  expect(await inkSpots(page)).toBeGreaterThan(4)
  await forget(page)

  await page.locator("#fleet-tab-hall").focus()
  await page.keyboard.press("Enter")
  await expect(page.locator("#fleet-tab-hall")).toHaveAttribute("aria-current", "page")
  await expect.poll(() => markUnder(page, "#fleet-tab-hall")).toBe(true)
  expect(await inkSpots(page)).toBeLessThanOrEqual(1)
})

test.describe("on a phone", () => {
  test.use({viewport: {width: 390, height: 844}, hasTouch: true, isMobile: true})

  test("the mark stays under the open tab as the row scrolls to it", async ({page}) => {
    await openFleet(page)
    const width = await page.locator("#fleet-tabs").evaluate(row => row.scrollWidth)
    await page.locator("#fleet-tab-proposals").tap()
    await expect(page.locator("#fleet-tab-proposals")).toHaveAttribute("aria-current", "page")
    await expect.poll(() => markUnder(page, "#fleet-tab-proposals")).toBe(true)
    expect(await page.locator("#fleet-tabs").evaluate(row => row.scrollWidth)).toBe(width)
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390)
  })
})

test("Buy pressed again and again squishes only its label, which ends at rest, and every press is answered", async ({
  page,
}) => {
  // Sign-in's own code, standing in for Privy, notes what it is asked.
  await page.route(/\/assets\/js\/privy_bridge(?:-[a-f0-9]{32})?\.js\?(?:vsn=d&)?regent_retry=\d+$/, route =>
    route.fulfill({
      contentType: "application/javascript",
      body: `export async function startPrivyBridge() {
        return {async request(request) { window.__bridgeCalls = [...(window.__bridgeCalls || []), request] }}
      }`,
    }),
  )
  await openFleet(page)
  await page.locator("#fleet-get-key").click()
  await expect(page.locator("#buy-key-button")).toBeVisible()
  await page.waitForTimeout(1_000)
  await forget(page)

  await pressRapidly(page, "#buy-key-button")
  await page.waitForTimeout(1_000)

  expect(await moved(page, "#buy-key-button [data-press-label]")).toBe(true)
  expect(await moved(page, "#buy-key-button")).toBe(false)
  expect(await leftovers(page)).toEqual([])
  // Signed out, a press opens sign-in and sends nothing.
  await expect
    .poll(() => page.evaluate(() => (window as Window & {__bridgeCalls?: string[]}).__bridgeCalls ?? []))
    .toContain("sign-in")
  await expect(page.locator("#buy-key-order-press-note")).toHaveCount(0)
})

test("a sale rolls the count, each digit clipped by class, and its line joins the top of the feed while the lines already there glide down, ending as plain text", async ({page}) => {
  // An earlier sale and that key changing hands, so the feed has lines already
  // there and the next sale, no longer part of a run of sales, joins as its own line.
  const earlier = sellKey(quiet, buyer)
  moveKey(quiet, earlier, heir)
  await openFleet(page, "/accelerant/1")
  await expect(page.locator("#fleet-feed-list > li").first()).toContainText(`Key ${earlier} moved to 0x3333..3333`, {
    timeout: 10_000,
  })
  await expect.poll(() => leftovers(page)).toEqual([])
  const sold = Number(await plainNumber(page, "fleet-sales-keys"))
  // The list's layout motion styles every line while it runs, so what counts is
  // where each line already there is drawn, frame by frame.
  await page.evaluate(() => {
    const list = document.querySelector("#fleet-feed-list")!
    const top = (line: Element) => line.getBoundingClientRect().top - list.getBoundingClientRect().top
    const paths = new Map([...list.children].map(line => [line, [top(line)]]))
    Object.assign(window, {__feedPaths: paths})
    const sample = () => {
      for (const [line, path] of paths) if (line.isConnected) path.push(top(line))
      requestAnimationFrame(sample)
    }
    requestAnimationFrame(sample)
  })

  sellKey(quiet, buyer)

  await expect.poll(() => plainNumber(page, "fleet-sales-keys")).toBe(String(sold + 1))
  expect(await rolled(page, "fleet-sales-keys")).toBe(true)
  // Each digit rolls in a box its stylesheet clips, not one styled in markup.
  expect(await clippedByClass(page, "fleet-sales-keys")).toBe(true)
  // The feed hears of the sale a moment after the count does.
  await expect(page.locator("#fleet-feed-list > li[data-kind=sale]").first()).toContainText(
    new RegExp(`\\b${sold + 1} w[a-z]+ bought`),
    {timeout: 10_000},
  )
  await page.waitForTimeout(600)
  // Each line already there ends lower by the new line and the gap, and glides
  // there: no frame moves it as much as half the way, which a jump would.
  const glides = await page.evaluate(() =>
    [...(window as unknown as {__feedPaths: Map<Element, number[]>}).__feedPaths.values()].map(path => ({
      travel: path.at(-1)! - path[0],
      step: Math.max(...path.slice(1).map((y, i) => Math.abs(y - path[i]))),
    })),
  )
  expect(glides.length).toBeGreaterThan(0)
  for (const {travel, step} of glides) {
    expect(travel).toBeGreaterThan(8)
    expect(step).toBeLessThan(travel / 2)
  }
  await expect.poll(() => leftovers(page)).toEqual([])
})

test("a reader who asked for less motion sees presses, panels and a sale without movement", async ({browser}) => {
  const context = await browser.newContext({reducedMotion: "reduce"})
  const page = await context.newPage()
  await openFleet(page)
  const sold = Number(await plainNumber(page, "fleet-sales-keys"))

  await page.locator("#fleet-show-chat").click()
  await page.locator("#fleet-get-key").click()
  await expect(page.locator("dialog#buy-key")).toBeVisible()
  await page.keyboard.press("Escape")
  await expect(page.locator("dialog#buy-key")).toHaveCount(0)
  sellKey(fleet, buyer)
  await expect.poll(() => plainNumber(page, "fleet-sales-keys")).toBe(String(sold + 1))
  await page.waitForTimeout(4_000)

  expect(await anythingMoved(page)).toBe(false)

  await forget(page)
  await page.locator("#fleet-tab-proposals").click()
  await expect.poll(() => markUnder(page, "#fleet-tab-proposals")).toBe(true)
  expect(await inkSpots(page)).toBeLessThanOrEqual(1)
  await context.close()
})
