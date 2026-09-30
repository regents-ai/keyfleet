import {expect, test} from "@playwright/test"

test("on a phone the About page's key facts fit the screen with nothing to scroll sideways", async ({page}) => {
  await page.setViewportSize({width: 375, height: 812})
  await page.goto("/about")

  const table = page.locator("main table")
  await expect(table.getByRole("cell", {name: "Token contract"})).toBeVisible()

  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(375)
  expect(await table.evaluate(element => element.scrollWidth - element.clientWidth)).toBe(0)
})
