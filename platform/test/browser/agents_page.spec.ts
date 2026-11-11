import {expect, test} from "@playwright/test"

// /agents lists every runtime by its name and what sets it apart, and a
// runtime that passed Keyfleet's checks is marked Verified. Nothing runs past
// the screen's edge.
test("/agents lists each runtime, with nothing past the edge on a phone or a desktop", async ({page}) => {
  for (const size of [{width: 390, height: 844}, {width: 1280, height: 720}]) {
    await page.setViewportSize(size)
    await page.goto("/agents")

    await expect(page.getByRole("heading", {name: "Agents", level: 1})).toBeVisible()
    for (const runtime of ["dots", "hermes", "codex"]) {
      await expect(page.locator(`main li a[href$="/agents/${runtime}"]`)).toBeVisible()
    }
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
  }
})
