import {expect, test, type Page} from "@playwright/test"
import {atRest} from "./support/first_visit"

// The homepage is the headline, one line under it, "Explore", Classic #1's figures and "Buy Key"
// under the Key's card art and price, then the four steps a person takes.

// No fleet in the test data is deployed, so Classic's sale is closed: "Buy Key" says it can't
// be pressed, with the reason under it.

const waitForHomepage = async (page: Page) => {
  await expect(page.locator("#public-home")).toBeVisible()
  await page.evaluate(async () => {
    await document.fonts.ready
    await Promise.all([...document.images].filter(image => !image.complete).map(image => image.decode()))
  })
}

test("the homepage reads without scripts", async ({browser}) => {
  const context = await browser.newContext({javaScriptEnabled: false})
  const page = await context.newPage()
  await page.goto("/")

  await expect(page.getByRole("heading", {name: "A persistent team for your AI agent.", level: 1}))
    .toBeVisible()
  const buy = page.locator("#home-buy-key")
  await expect(buy).toBeDisabled()
  await expect(buy).toHaveText("Buy Key")
  await expect(page.locator("#home-buy-tag")).toHaveText("Key 1 · 10 USDC")
  await expect(page.locator("#home-buy-why")).toHaveText("Sales open soon")
  await expect(page.getByRole("link", {name: "Explore", exact: true})).toHaveAttribute("href", "/classic/1")
  await expect(page.locator("#home-classic-facts")).toBeVisible()
  await context.close()
})

// The homepage follows the visitor's saved theme like every other page, and offers the switch.
test("the homepage shows the saved theme and offers the switch", async ({browser}) => {
  for (const saved of ["light", "dark"] as const) {
    const context = await browser.newContext()
    await context.addCookies([{name: "regent_theme", value: saved, url: test.info().project.use.baseURL as string}])
    const page = await context.newPage()
    await page.goto("/")
    await waitForHomepage(page)

    await expect(page.locator("html")).toHaveAttribute("data-theme", saved)
    await expect(page.locator("#theme-control")).toBeVisible()
    await context.close()
  }
})

// The steps come after the Key on offer, so Classic #1's figures and "Buy Key" keep their place:
// on a wide screen all three show on the first screen; on a phone, whose first screen ends above
// "Buy Key", the steps follow it.
test("the steps never push Buy Key or Classic #1's figures down", async ({page}) => {
  const bottom = (selector: string) =>
    page.locator(selector).evaluate(element => element.getBoundingClientRect().bottom)
  const top = (selector: string) => page.locator(selector).evaluate(element => element.getBoundingClientRect().top)

  await page.setViewportSize({width: 1280, height: 800})
  await page.goto("/")
  await waitForHomepage(page)
  await atRest(page)
  await expect(page.locator("#home-steps > li")).toHaveCount(4)
  expect(await bottom("#home-classic-facts")).toBeLessThanOrEqual(800)
  expect(await bottom("#home-buy-key")).toBeLessThanOrEqual(800)
  expect(await top("#home-steps")).toBeLessThan(800)

  await page.setViewportSize({width: 390, height: 844})
  await page.goto("/")
  await waitForHomepage(page)
  await atRest(page)
  expect(await bottom("#home-classic-facts")).toBeLessThanOrEqual(844)
  expect(await top("#home-steps")).toBeGreaterThanOrEqual(await bottom("#home-buy-why"))
})

// On a phone the page fits the screen, with the hero's "Buy Key" on it.
test("on a phone nothing scrolls sideways and Buy Key is there", async ({page}) => {
  for (const width of [320, 375]) {
    await page.setViewportSize({width, height: 812})
    await page.goto("/")
    await waitForHomepage(page)

    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
    await expect(page.locator("#home-buy-key")).toBeVisible()
  }
})
