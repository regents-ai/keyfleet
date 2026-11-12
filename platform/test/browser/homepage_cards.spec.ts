import {expect, test, type Page} from "@playwright/test"
import {prepareFleet} from "./support/fleet_chain"

// The homepage's Overview, the row of value cards under the hero. Each card
// opens a page of Classic #1 or Pair New Agent; Classic is deployed here, so
// every page of it is open, as it is on the live site. Each card shows its
// still frame until its panel draws, and keeps it for a visitor who asked for
// less motion or whose browser has no WebGPU. This runs with the chain to
// deploy Classic.
const cards = ["fleet", "rooms", "board", "link", "ballot", "ledger"]

test.beforeAll(() => {
  prepareFleet("fleet_tech_classic")
})

// The page's errors and the browser's console errors, refusals of the
// security policy among them.
function watchErrors(page: Page): string[] {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  page.on("console", message => {
    if (message.type() === "error") errors.push(message.text())
  })
  return errors
}

async function openHome(page: Page) {
  await page.goto("/")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
}

const card = (page: Page, name: string) => page.locator(`#home-cards [data-value-card="${name}"]`)

// Each card in turn on screen, its still frame shown and loaded.
async function eachShowsItsStill(page: Page) {
  for (const name of cards) {
    const still = card(page, name).locator("img.value-cards__still")
    await still.scrollIntoViewIfNeeded()
    await expect(still).toBeVisible()
    await expect.poll(() => still.evaluate((image: HTMLImageElement) => image.complete && image.naturalWidth)).toBe(600)
  }
}

// Every card keeps its still: none says its panel is drawing, and every
// drawing surface stays clear over the still.
async function eachKeepsItsStill(page: Page) {
  await eachShowsItsStill(page)
  for (const name of cards) {
    await expect(card(page, name)).not.toHaveAttribute("data-value-card-ready", "true")
    await expect(card(page, name).locator(".value-cards__stage")).toHaveCSS("opacity", "0")
  }
}

test("the Overview's cards each open a page anyone can read", async ({page}) => {
  const errors = watchErrors(page)
  await page.setViewportSize({width: 1280, height: 900})
  await openHome(page)

  const links = page.locator("#home-cards a.value-cards__face")
  await expect(links).toHaveCount(cards.length)
  for (const link of await links.all()) {
    const href = (await link.getAttribute("href"))!
    const response = await page.request.get(href, {maxRedirects: 0, headers: {accept: "text/html"}})
    expect(response.status(), href).toBe(200)
  }

  await eachShowsItsStill(page)
  expect(errors).toEqual([])
})

test("with less motion asked for, each card keeps its still", async ({page}) => {
  const errors = watchErrors(page)
  await page.emulateMedia({reducedMotion: "reduce"})
  await page.setViewportSize({width: 1280, height: 900})
  await openHome(page)

  await eachKeepsItsStill(page)
  expect(errors).toEqual([])
})

test("in a browser without WebGPU, each card keeps its still", async ({page}) => {
  const errors = watchErrors(page)
  await page.addInitScript(() => Object.defineProperty(Navigator.prototype, "gpu", {get: () => undefined}))
  await page.setViewportSize({width: 1280, height: 900})
  await openHome(page)

  await eachKeepsItsStill(page)
  expect(errors).toEqual([])
})

for (const width of [320, 390]) {
  test(`the Overview fits ${width} wide without scrolling sideways`, async ({page}) => {
    await page.setViewportSize({width, height: 844})
    await openHome(page)

    await eachShowsItsStill(page)
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
  })
}

test("the keyboard reaches every card, in order", async ({page}) => {
  await page.setViewportSize({width: 1280, height: 900})
  await openHome(page)

  const reached: string[] = []
  for (let press = 0; press < 60 && reached.length < cards.length; press++) {
    await page.keyboard.press("Tab")
    const name = await page.evaluate(() => document.activeElement?.closest<HTMLElement>("#home-cards [data-value-card]")?.dataset.valueCard)
    if (name && !reached.includes(name)) {
      reached.push(name)
      await expect(card(page, name).locator("a.value-cards__face")).toBeFocused()
      await expect(card(page, name).locator("a.value-cards__face")).toBeInViewport()
    }
  }
  expect(reached).toEqual(cards)
})
