import {expect, test, type Page} from "@playwright/test"
import {prepareFleet} from "./support/fleet_chain"

// A fleet page's layout: the hall's columns scroll inside the fleet's box and
// never run past its edge, and the way in is a filled Tangerine button with
// Charcoal words in both themes.
const fleet = "fleet_tech_classic"

test.beforeAll(() => {
  prepareFleet(fleet)
})

async function openFleet(page: Page) {
  await page.goto(`/classic/1`)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  await expect(page.locator("#fleet-hall")).toBeVisible()
}

const bottoms = (page: Page) =>
  page.evaluate(() => {
    const bottom = (selector: string) => document.querySelector(selector)!.getBoundingClientRect().bottom
    return {
      view: bottom("#fleet-view"),
      hall: bottom("#fleet-hall"),
      columns: [...document.querySelectorAll("#fleet-hall > *")].map(column => column.getBoundingClientRect().bottom),
    }
  })

for (const [width, height] of [
  [1440, 900],
  [1280, 700],
  [1280, 560],
]) {
  test(`at ${width}×${height} the hall ends inside the fleet's box`, async ({page}) => {
    await page.setViewportSize({width, height})
    await openFleet(page)

    const {view, hall, columns} = await bottoms(page)
    expect(hall).toBeLessThanOrEqual(view)
    for (const column of columns) expect(column).toBeLessThanOrEqual(view)
  })
}

test("on a tall screen the hall fills the box to the screen's foot and scrolls on its own", async ({page}) => {
  await page.setViewportSize({width: 1440, height: 900})
  await openFleet(page)

  const {view, hall} = await bottoms(page)
  // The page's own margin is all that lies under the box.
  const margin = await page.locator("#route-content").evaluate(el => parseFloat(getComputedStyle(el).paddingBottom))
  expect(Math.abs(900 - margin - view)).toBeLessThanOrEqual(1)
  expect(view - hall).toBeLessThanOrEqual(2)
  const scroller = page.locator("#app-shell-scroller")
  expect(await scroller.evaluate(el => el.scrollHeight <= el.clientHeight + 1)).toBe(true)
})

for (const scheme of ["light", "dark"] as const) {
  test(`"Get a Key" is filled Tangerine with Charcoal words in ${scheme}`, async ({page, baseURL}) => {
    // The theme the visitor chose, as the switch writes it.
    await page.context().addCookies([{name: "regent_theme", value: scheme, url: baseURL!}])
    await openFleet(page)
    await expect(page.locator("html")).toHaveAttribute("data-theme", scheme)

    const button = page.locator("#fleet-get-key")
    await expect(button).toHaveText(/Join this Keyfleet by purchasing the next Key: [0-9.,]+ USDC/)
    const paint = await button.evaluate(element => ({
      fill: getComputedStyle(element, "::before").backgroundColor,
      ink: getComputedStyle(element).color,
    }))
    expect(paint).toEqual({fill: "rgb(255, 91, 25)", ink: "rgb(22, 22, 22)"})
  })
}
