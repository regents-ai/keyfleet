import {expect, type Page} from "@playwright/test"

// Opens the reference page on a fleet and waits for the first tiles.
export async function openMap(page: Page, fleet: "Fibonacci" | "Classic" | "Accelerant") {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  await page.goto("/showcase/key-map")
  // The first map is ready only once the page is live, so the fleet buttons work.
  await expect(page.locator(".key-map.key-map--ready")).toBeVisible()
  if (fleet !== "Fibonacci") await page.getByRole("button", {name: new RegExp(`^${fleet}`)}).click()
  const stage = page.locator(`#key-map-${fleet.toLowerCase()}.key-map--ready`)
  await expect(stage).toBeVisible()
  await expect(stage.locator(".km-tile").first()).toBeAttached()
  await stage.scrollIntoViewIfNeeded()
  return {stage, errors}
}

export const settle = (page: Page) => page.evaluate(() => new Promise(done => setTimeout(done, 1_500)))
