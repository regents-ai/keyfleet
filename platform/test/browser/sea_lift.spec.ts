import {expect, test} from "@playwright/test"
import {prepareFleet} from "./support/fleet_chain"

// The city button beside a fleet's name lifts the page away to show the city.
// A bar at the top names the fleet and opens its Chat or Workspace; the
// fleet's name, Escape, or either link brings the page back. Only an open
// fleet's page has the button, so this runs in the chain suite.
test.beforeAll(() => {
  prepareFleet("fleet_tech_classic")
})

test("the city button beside the fleet's name lifts the page, and the bar and Escape bring it back", async ({page}) => {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  await page.goto("/classic/1")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  const lift = page.locator(".fleet-bar__title > #sea-lift")
  await expect(lift).toHaveAccessibleName("Show the city")
  await expect(page.locator("#shell-header #sea-lift")).toHaveCount(0)

  const back = page.locator("#sea-return")
  await lift.click()
  await expect(page.locator("body")).toHaveAttribute("data-sea-lifted")
  await expect(page.locator("#app-shell")).toBeHidden()
  await expect(back).toHaveText("Keyfleet Classic #1")
  await expect(back).toBeFocused()
  await expect(page.locator("#sea-chat")).toBeVisible()
  await expect(page.locator("#sea-workspace")).toBeVisible()

  await back.click()
  await expect(page.locator("body")).not.toHaveAttribute("data-sea-lifted")
  await expect(page.locator("#app-shell")).toBeVisible()
  await expect(lift).toBeFocused()

  await lift.click()
  await expect(page.locator("body")).toHaveAttribute("data-sea-lifted")
  await page.keyboard.press("Escape")
  await expect(page.locator("body")).not.toHaveAttribute("data-sea-lifted")

  await lift.click()
  await page.locator("#sea-workspace").click()
  await expect(page).toHaveURL(/\/classic\/1\/workspace$/)
  await expect(page.locator("body")).not.toHaveAttribute("data-sea-lifted")
  await expect(page.locator("#app-shell")).toBeVisible()
  expect(errors).toEqual([])
})
