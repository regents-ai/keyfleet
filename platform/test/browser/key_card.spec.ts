import {expect, test, type Page} from "@playwright/test"
import {prepareFleet, sellKey} from "./support/fleet_chain"

// A Key's page shows its card beside its number. Under a mouse the card turns
// toward the pointer and a light crosses it; both settle once the mouse leaves.
// Less motion, and a finger, get the card as it is.
const fleet = "fibonacci_cascade"
const holder = "0x1111111111111111111111111111111111111111"
const fleetPath = `/cascade/1`

let key: number

async function openKey(page: Page) {
  await page.goto(`${fleetPath}/keys/${key}`)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  await expect(page.locator("#key-card-picture")).toBeVisible()
}

const turn = (page: Page) =>
  page.locator("#key-card [data-key-tilt]").evaluate(el => getComputedStyle(el).transform)

test.beforeAll(() => {
  prepareFleet(fleet)
  key = sellKey(fleet, holder)
})

test("the card turns toward a mouse and settles level when it leaves", async ({page}) => {
  await page.setViewportSize({width: 1280, height: 900})
  await openKey(page)
  const box = (await page.locator("#key-card").boundingBox())!

  await page.mouse.move(box.x + box.width * 0.5, box.y + box.height * 0.5)
  await page.mouse.move(box.x + box.width * 0.9, box.y + box.height * 0.1, {steps: 8})
  await expect.poll(() => turn(page)).not.toBe("none")
  await expect
    .poll(() => page.locator("#key-card [data-key-light]").evaluate(el => Number(getComputedStyle(el).opacity)))
    .toBeGreaterThan(0.5)

  await page.mouse.move(5, 5, {steps: 4})
  await expect.poll(() => turn(page)).toBe("none")
  await expect
    .poll(() => page.locator("#key-card [data-key-light]").evaluate(el => Number(getComputedStyle(el).opacity)))
    .toBe(0)
})

test.describe("with less motion", () => {
  test.use({contextOptions: {reducedMotion: "reduce"}})

  test("the card stays still under a mouse", async ({page}) => {
    await page.setViewportSize({width: 1280, height: 900})
    await openKey(page)
    const box = (await page.locator("#key-card").boundingBox())!
    await page.mouse.move(box.x + box.width * 0.9, box.y + box.height * 0.1, {steps: 8})
    await page.waitForTimeout(500)
    expect(await turn(page)).toBe("none")
  })
})

test.describe("on a phone", () => {
  test.use({viewport: {width: 390, height: 844}, hasTouch: true, isMobile: true})

  test("the card sits under the number, inside the screen", async ({page}) => {
    await openKey(page)
    const card = (await page.locator("#key-card").boundingBox())!
    const title = (await page.locator("#key-page h1").boundingBox())!
    expect(card.y).toBeGreaterThan(title.y + title.height)
    expect(card.x).toBeGreaterThanOrEqual(0)
    expect(card.x + card.width).toBeLessThanOrEqual(390)
    expect(card.height).toBeLessThanOrEqual(844 * 0.4 + 1)
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390)
  })
})
