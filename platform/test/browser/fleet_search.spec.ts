import {expect, test} from "@playwright/test"
import {prepareFleet, sayInPublic} from "./support/fleet_chain"

// The fleet bar's search box opens the fleet's search, whose lines open the
// page each match is on. Each run searches for a word of its own, so a
// retried worker's posts are never mistaken for its own.
const fleet = "fleet_tech_classic"
const owner = "0x7777777777777777777777777777777777777777"

test.beforeAll(() => {
  prepareFleet(fleet)
})

for (const width of [390, 1280]) {
  test(`the bar's search finds a post and opens its room at ${width} wide`, async ({page}, info) => {
    const word = `probe${Math.random().toString(36).slice(2, 8)}`
    sayInPublic(fleet, owner, `The ${word} deploy went out at noon`)

    const errors: string[] = []
    page.on("pageerror", error => errors.push(error.message))
    await page.setViewportSize({width, height: 900})
    await page.goto("/classic/1")
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()

    const box = page.getByRole("searchbox", {name: "Search this fleet"})
    await box.fill(word)
    await box.press("Enter")

    await expect(page).toHaveURL(new RegExp(`/classic/1/search\\?q=${word}$`))
    const line = page.locator("#search-matches li").filter({hasText: word})
    await expect(line).toHaveCount(1)
    await expect(line).toContainText("Public")
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
    await page.screenshot({path: info.outputPath(`fleet-search-${width}.png`)})

    await line.getByRole("link").click()
    await expect(page).toHaveURL(/\/classic\/1\?room=general$/)
    await expect(page.locator("#rooms-thread").getByText(word)).toBeVisible()
    expect(errors).toEqual([])
  })
}
