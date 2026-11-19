import {expect, test} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {call, prepareFleet, sellKey} from "./support/fleet_chain"

// A Key holder's Season panel on the fleet's hall: the season under way, the
// last one's result, and the pick for the next, locked from the form; then
// Record opens the fleet's settled seasons, the 24h figure over them, and a
// season's row opens to its picks. Nothing on the page fails, and neither
// page scrolls sideways, at a phone's width or a laptop's.
const fleet = "fibonacci_syndicate"
const me = "0x1111111111111111111111111111111111111111"

test.beforeAll(() => {
  prepareFleet(fleet)
  sellKey(fleet, me)
  call("seasons!", [fleet, me])
})

const sideways = (page: import("@playwright/test").Page) =>
  page.evaluate(() => document.documentElement.scrollWidth)

for (const width of [390, 1280]) {
  test(`a Key holder locks a pick and reads the record at ${width} wide`, async ({page}, info) => {
    const errors: string[] = []
    page.on("pageerror", error => errors.push(error.message))
    await page.setViewportSize({width, height: 900})
    await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
    await page.goto("/syndicate/1")
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()

    const panel = page.locator("#fleet-season")
    await panel.scrollIntoViewIfNeeded()
    await expect(panel.locator("#fleet-season-holding")).toContainText("SOL-USD")
    await expect(panel.locator("#fleet-season-holding")).toContainText("$143.27")
    await expect(panel.locator("#fleet-season-captain")).toHaveText("Key 1")
    await expect(panel.locator("#fleet-season-last")).toContainText("+10.00%")
    await expect(panel.locator("#fleet-season-last")).toContainText("Crown kept")
    await expect(panel.locator("#fleet-season-pick-list")).toContainText("Momentum")

    const reason = `Cheaper gas at ${width}`
    await panel.getByLabel("Product").selectOption("ETH-USD")
    await panel.getByLabel("Reason (optional)").fill(reason)
    await panel.getByRole("button", {name: "Lock"}).click()
    await expect(panel.locator("#fleet-season-note")).toHaveText("Locked.")
    await expect(panel.locator("#fleet-season-mine")).toContainText("ETH-USD")
    await expect(panel.locator("#fleet-season-mine")).toContainText(reason)
    expect(await sideways(page)).toBeLessThanOrEqual(width)
    await panel.locator("#fleet-season-pick").scrollIntoViewIfNeeded()
    await page.screenshot({path: info.outputPath(`season-panel-${width}.png`)})

    await panel.getByRole("link", {name: "Record"}).click()
    await expect(page).toHaveURL(/\/syndicate\/1\/seasons$/)
    const record = page.locator("#seasons-page")
    await expect(record.locator("#seasons-day")).toContainText("+114.36%")
    await expect(record.locator("#seasons-day")).toContainText("8 seasons")
    await expect(record.locator("#seasons-rows > tr:not([hidden])")).toHaveCount(9)

    const ninth = record.locator("#seasons-9").getByRole("button")
    await ninth.click()
    await expect(ninth).toHaveAttribute("aria-expanded", "true")
    const pick = record.locator("#seasons-9-pick-list li")
    await expect(pick).toHaveCount(1)
    await expect(pick).toContainText("ETH-USD")
    await expect(pick).toContainText("+5.00%")
    await expect(pick).toContainText("Gas is cheap")
    expect(await sideways(page)).toBeLessThanOrEqual(width)
    await record.locator("#seasons-day").scrollIntoViewIfNeeded()
    await page.screenshot({path: info.outputPath(`season-record-${width}.png`)})

    expect(errors).toEqual([])
  })
}
