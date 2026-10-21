import {expect, test} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {addWork, itemPath, openWorkspace, prepareFleet, pushCode, reworkItem, sellKey} from "./support/fleet_chain"
import {forget, leftovers, moved, watchMotion} from "./support/motion"

// A change to the fleet's work glides into the workstream a visitor watches,
// a push glides into the code's Sent lately and a change into an item's
// History while a Key holder watches, and each list ends clean.
const fleet = "fibonacci_cascade"
const me = "0x1111111111111111111111111111111111111111"

test.beforeAll(() => {
  prepareFleet(fleet)
  openWorkspace(fleet)
  addWork(fleet, 17, "Read the brief")
})

test("new work glides into the public workstream and ends clean", async ({page}) => {
  await watchMotion(page)
  await page.goto("/cascade/1/workspace")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  const lines = page.locator("#workspace-public-activity > li")
  const before = await lines.count()
  await forget(page)

  // Another Key's change makes a line of its own; the same Key's would join its line.
  addWork(fleet, 18, "Draft the plan")

  await expect(lines).toHaveCount(before + 1)
  await expect.poll(() => moved(page, "#workspace-public-activity > li:first-child")).toBe(true)
  await expect.poll(() => leftovers(page)).toEqual([])
})

test("a new push glides into Sent lately and ends clean", async ({page}) => {
  const key = sellKey(fleet, me)
  pushCode(fleet, key, me, "1".repeat(40))
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  await watchMotion(page)
  await page.goto("/cascade/1/workspace?place=code")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  const lines = page.locator("#code-pushes > li")
  await expect(lines).toHaveCount(1)
  await forget(page)

  pushCode(fleet, key, me, "2".repeat(40))

  await expect(lines).toHaveCount(2)
  await expect.poll(() => moved(page, "#code-pushes > li:first-child")).toBe(true)
  await expect.poll(() => leftovers(page)).toEqual([])
})

test("a change glides into an item's History and ends clean", async ({page}) => {
  const key = sellKey(fleet, me)
  const id = addWork(fleet, key, "Sketch the map")
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  await watchMotion(page)
  await page.goto(itemPath(fleet, id))
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  const lines = page.locator("#workspace-history > li")
  const before = await lines.count()
  await forget(page)

  reworkItem(fleet, key, id, "Sketch the sea chart")

  await expect(lines).toHaveCount(before + 1)
  await expect.poll(() => moved(page, "#workspace-history > li:first-child")).toBe(true)
  await expect.poll(() => leftovers(page)).toEqual([])
})
