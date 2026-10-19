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
  test(`"Purchase Key" is filled Tangerine with Charcoal words in ${scheme}`, async ({page, baseURL}) => {
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

// Nothing in the fleet's box sits under the open "Purchase Key" panel (Sean, 19
// October 2026): on a wide screen what the box holds moves over to leave the
// panel its own column, and narrower the panel covers the whole box.
const underPanel = (page: Page) =>
  page.evaluate(() => {
    const panel = document.querySelector("#fleet-about")!.getBoundingClientRect()
    return [...document.querySelectorAll(".fleet-stage *")]
      .filter(el => !el.closest("#fleet-about") && el.children.length === 0 && el.textContent!.trim())
      .filter(el => {
        const box = el.getBoundingClientRect()
        return box.width > 0 && box.right > panel.left + 1 && box.left < panel.left && box.bottom > panel.top && box.top < panel.bottom
      })
      .map(el => el.textContent!.trim().slice(0, 40))
  })

for (const width of [1440, 1280, 1024]) {
  test(`at ${width} wide nothing in the box sits under the open "Purchase Key"`, async ({page}) => {
    await page.setViewportSize({width, height: 900})
    await page.goto(`/classic/1?buy`)
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
    await expect(page.locator("#fleet-about")).toBeVisible()

    for (const tab of ["hall", "treasury"]) {
      if (tab === "treasury") {
        await page.locator("#fleet-tab-treasury").click()
        await expect(page.locator("#fleet-view")).toHaveAttribute("data-view", "treasury")
        await expect(page.locator("#fleet-about")).toBeVisible()
      }
      expect(await underPanel(page)).toEqual([])
      if (width < 1120) {
        const [panel, stage] = await Promise.all(
          ["#fleet-about", "#fleet-view > .fleet-stage"].map(selector => page.locator(selector).boundingBox()),
        )
        expect(Math.abs(panel!.x - stage!.x)).toBeLessThanOrEqual(1)
      }
    }
  })
}
