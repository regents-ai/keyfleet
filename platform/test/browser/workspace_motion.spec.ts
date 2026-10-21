import {expect, test} from "@playwright/test"
import {addWork, openWorkspace, prepareFleet} from "./support/fleet_chain"
import {forget, leftovers, moved, watchMotion} from "./support/motion"

// A change to the fleet's work glides into the workstream a visitor watches,
// and the list ends clean.
const fleet = "fibonacci_cascade"

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
