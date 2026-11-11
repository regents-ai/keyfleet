import {expect, test, type Page} from "@playwright/test"

// The homepage leads with the headline, the ways in, Classic #1's figures and "Buy Key" under
// the Key's card art and price, then Classic Keyfleet with "Buy Key", what a fleet can use and
// the starting ideas for a fleet's shared goal.

// No fleet in the test data is deployed, so Classic's sale is closed: "Buy Key" says it can't
// be pressed, with the reason under it.

const waitForHomepage = async (page: Page) => {
  await expect(page.locator("#public-home")).toBeVisible()
  await page.evaluate(async () => {
    await document.fonts.ready
    await Promise.all([...document.images].filter(image => !image.complete).map(image => image.decode()))
  })
}

test("the homepage reads without scripts, top to bottom", async ({browser}) => {
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
  await expect(page.locator("#home-integration-tiles > li")).toHaveCount(9)
  await expect(page.getByRole("heading", {name: "Shared Goals", level: 2}))
    .toBeVisible()
  await expect(page.locator("#home-goal-idea-tiles > li")).toHaveCount(8)
  await context.close()
})

// The ideas are tiles four across on a wide screen, two on a tablet and one on a phone,
// and their links name the sites they open.
test("the starting ideas lay out by width, and each link names its site", async ({page}) => {
  for (const [width, across] of [[1440, 4], [800, 2], [375, 1]] as const) {
    await page.setViewportSize({width, height: 900})
    await page.goto("/")
    await waitForHomepage(page)

    const tops = await page.locator("#home-goal-idea-tiles > li").evaluateAll(tiles =>
      tiles.map(tile => Math.round(tile.getBoundingClientRect().top)))
    expect(tops.filter(top => top === tops[0])).toHaveLength(across)
  }

  const ideas = page.locator("#home-goal-ideas")
  await expect(ideas.getByRole("link", {name: "Yukon"})).toHaveAttribute("href", "https://yukon.org/")
  await expect(ideas.getByRole("link", {name: "Autolaunch"})).toHaveCount(2)
  await expect(ideas.getByRole("link", {name: "OpenEnv Arena"})).toHaveAttribute("target", "_blank")
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
