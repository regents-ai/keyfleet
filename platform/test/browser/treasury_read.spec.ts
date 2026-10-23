import {expect, test} from "@playwright/test"
import {prepareFleet, readTreasury} from "./support/fleet_chain"

// A fleet's balances are read every five minutes. The Treasury page says when
// they were last read, and its refresh icon reads them again at once.
const fleet = "fleet_tech_classic"

test.beforeAll(() => {
  prepareFleet(fleet)
  readTreasury(fleet, 40_000_000)
})

for (const width of [390, 1280]) {
  test(`the Treasury says when its balances were read, and its icon reads them again at ${width} wide`, async ({page}, info) => {
    const errors: string[] = []
    page.on("pageerror", error => errors.push(error.message))
    await page.setViewportSize({width, height: 900})
    await page.goto("/classic/1/treasury")
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()

    await expect(page.locator("#proposals-read")).toHaveText(/Updated \d{1,2} \w{3}, \d{2}:\d{2} UTC/)
    const again = page.getByRole("button", {name: "Refresh balances", exact: true})
    await expect(again).toBeEnabled()
    const box = await again.boundingBox()
    expect(Math.round(box!.width)).toBe(Math.round(box!.height))
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)

    // A press reads the balances at once, and the icon rests until it may be pressed again.
    await again.click()
    await expect(again).toBeDisabled()
    await page.screenshot({path: info.outputPath(`treasury-read-${width}.png`)})
    expect(errors).toEqual([])
  })
}
