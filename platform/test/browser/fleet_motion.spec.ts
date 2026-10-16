import {expect, test, type Page} from "@playwright/test"
import {prepareFleet, sellKey} from "./support/fleet_chain"
import {
  anythingMoved,
  clippedByClass,
  forget,
  leftovers,
  moved,
  pressRapidly,
  rolled,
  watchMotion,
} from "./support/motion"

// A fleet page's motion: presses squish and dialogs rise only for a pointer,
// "Get a Key" simply opens, a sale rolls its numbers and its line
// joins the hall's feed, and everything ends clean. Nothing moves for a reader
// who asked for less motion.
const fleet = "fleet_tech_classic"
const buyer = "0x2222222222222222222222222222222222222222"

test.beforeAll(() => {
  prepareFleet(fleet)
})

async function openFleet(page: Page) {
  await watchMotion(page)
  await page.goto(`/classic/1`)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  await forget(page)
}

const plainNumber = (page: Page, id: string) =>
  page.locator(`#${id} [data-count]`).evaluate(el => (el.children.length === 0 ? el.textContent!.trim() : null))

test("a pointer press squishes its control and rises a dialog, all ending clean", async ({page}) => {
  await openFleet(page)

  await page.locator("#fleet-show-chat").click()
  await expect(page.locator("#fleet-show-chat")).toHaveAttribute("aria-pressed", "true")
  await expect.poll(() => moved(page, "#fleet-show-chat")).toBe(true)

  await page.locator("#fleet-get-key").click()
  await expect(page.locator("#fleet-about")).toBeVisible()
  await expect.poll(() => moved(page, "#fleet-get-key")).toBe(true)
  await page.waitForTimeout(600)
  expect(await moved(page, "#fleet-about")).toBe(false)

  await page.locator("#fleet-send-agent").click()
  await expect(page.locator("dialog.send-agent")).toBeVisible()
  await expect.poll(() => moved(page, "dialog.send-agent")).toBe(true)

  await expect.poll(() => leftovers(page)).toEqual([])
})

test("a keyboard press picks a channel and opens panels and dialogs at once, with no squish", async ({page}) => {
  await openFleet(page)

  await page.locator("#fleet-show-chat").focus()
  await page.keyboard.press("Enter")
  await expect(page.locator("#fleet-show-chat")).toHaveAttribute("aria-pressed", "true")
  await page.locator("#fleet-get-key").focus()
  await page.keyboard.press("Enter")
  await expect(page.locator("#fleet-about")).toBeVisible()
  // Opening a panel takes the reader to its heading, and again two frames later.
  await page.evaluate(
    () => new Promise(done => requestAnimationFrame(() => requestAnimationFrame(() => requestAnimationFrame(done)))),
  )
  await page.locator("#fleet-send-agent").focus()
  await page.keyboard.press("Enter")
  await expect(page.locator("dialog.send-agent")).toBeVisible()
  await page.waitForTimeout(600)

  expect(await anythingMoved(page)).toBe(false)
})

test("Buy pressed again and again squishes only its label, which ends at rest, and every press is answered", async ({
  page,
}) => {
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
  // Signed out, a press sends nothing and says so.
  await expect(page.locator("#buy-key-order-press-note")).toHaveText("Sign in to send this. Nothing was sent.")
})

test("a sale rolls the count, each digit clipped by class, and its line joins the feed without moving the lines below, ending as plain text", async ({page}) => {
  await openFleet(page)
  const sold = Number(await plainNumber(page, "fleet-sales-keys"))
  // The list's layout motion styles every line while it runs, so what counts is
  // where each line already there is drawn, frame by frame.
  await page.evaluate(() => {
    const list = document.querySelector("#fleet-feed-list")!
    const top = (line: Element) => line.getBoundingClientRect().top - list.getBoundingClientRect().top
    const lines = new Map([...list.children].map(line => [line, top(line)]))
    const drift = {most: 0}
    Object.assign(window, {__feedDrift: drift})
    const sample = () => {
      for (const [line, start] of lines) if (line.isConnected) drift.most = Math.max(drift.most, Math.abs(top(line) - start))
      requestAnimationFrame(sample)
    }
    requestAnimationFrame(sample)
  })

  sellKey(fleet, buyer)

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
  expect(await page.evaluate(() => (window as unknown as {__feedDrift: {most: number}}).__feedDrift.most)).toBeLessThan(0.5)
  await expect.poll(() => leftovers(page)).toEqual([])
})

test("a panel closed while its key number rolls shows the new number whole", async ({page}) => {
  await openFleet(page)
  await page.locator("#fleet-get-key").click()
  await expect(page.locator("#buy-key-number")).toBeVisible()
  const next = String(Number(await plainNumber(page, "buy-key-number")) + 1)

  // The moment the number splits to roll, the reader closes the panel.
  await page.evaluate(() => {
    const number = document.querySelector("#buy-key-number [data-count]") as HTMLElement
    const closeMidRoll = new MutationObserver(() => {
      if (number.children.length === 0) return
      closeMidRoll.disconnect()
      ;(document.querySelector("#fleet-about-close") as HTMLElement).click()
    })
    closeMidRoll.observe(number, {childList: true})
  })
  sellKey(fleet, buyer)

  await expect(page.locator("#fleet-about")).toBeHidden({timeout: 10_000})
  expect(await rolled(page, "buy-key-number")).toBe(true)
  await expect.poll(() => plainNumber(page, "buy-key-number")).toBe(next)
})

test("a reader who asked for less motion sees presses, panels and a sale without movement", async ({browser}) => {
  const context = await browser.newContext({reducedMotion: "reduce"})
  const page = await context.newPage()
  await openFleet(page)
  const sold = Number(await plainNumber(page, "fleet-sales-keys"))

  await page.locator("#fleet-show-chat").click()
  await page.locator("#fleet-get-key").click()
  await page.locator("#fleet-send-agent").click()
  await expect(page.locator("dialog.send-agent")).toBeVisible()
  await page.keyboard.press("Escape")
  sellKey(fleet, buyer)
  await expect.poll(() => plainNumber(page, "fleet-sales-keys")).toBe(String(sold + 1))
  await page.waitForTimeout(4_000)

  expect(await anythingMoved(page)).toBe(false)
  await context.close()
})
