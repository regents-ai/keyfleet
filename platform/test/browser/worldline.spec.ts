import {expect, test, type Locator, type Page} from "@playwright/test"
import {prepareFleet, writeHistory} from "./support/fleet_chain"

// A fleet's Worldline, read signed out: the picture draws a fortnight of the
// fleet's history, the mark pointed at links to the page it happened on, in
// a new tab too, a drag moves the picture through time, and the list's links
// open their pages. The walk asks for less motion, so nothing orbits and a
// mark stays where it was found. The owner's wallet is used by no other spec.
const fleet = "fleet_tech_classic"
const owner = "0x7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d"

// The headless shell Playwright runs by default hands out no WebGPU canvas
// textures, so the picture never draws there; full Chromium draws it.
test.use({channel: "chromium"})

test.beforeAll(() => {
  prepareFleet(fleet)
  writeHistory(fleet, owner)
})

// Moves the mouse along rows of the picture, left to right from `from`, until
// a mark's link shows, and answers where.
async function pointAtMark(page: Page, stage: Locator, link: Locator, from = 0.08) {
  const box = (await stage.boundingBox())!
  for (const row of [0.5, 0.42, 0.58, 0.34, 0.66]) {
    for (let x = box.width * from; x < box.width * 0.55; x += 10) {
      const at = {x: box.x + x, y: box.y + box.height * row}
      await page.mouse.move(at.x, at.y)
      if (await link.isVisible()) return at
    }
  }
  throw new Error("no mark found in the picture")
}

const sideways = (page: Page) => page.evaluate(() => document.documentElement.scrollWidth)
const path = (url: string) => {
  const {pathname, search} = new URL(url)
  return pathname + search
}

for (const width of [390, 1280]) {
  test(`a signed-out reader moves through the Worldline and opens its events at ${width} wide`, async ({page}, info) => {
    const errors: string[] = []
    page.on("pageerror", error => errors.push(error.message))
    await page.emulateMedia({reducedMotion: "reduce"})
    await page.setViewportSize({width, height: 900})
    await page.goto("/classic/1/worldline")
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()

    const stage = page.locator("#worldline-stage")
    const link = page.locator("[data-worldline-focus]")
    await expect(stage).toHaveAttribute("data-worldline-ready", "true")
    await expect(page.locator("#worldline-legend")).toContainText("Chat")
    await expect(page.locator("#worldline-legend")).not.toContainText("Workspace")
    expect(await sideways(page)).toBeLessThanOrEqual(width)
    await page.screenshot({path: info.outputPath(`worldline-${width}.png`)})

    // The mark pointed at shows what it was, who did it and when.
    const found = await pointAtMark(page, stage, link)
    await expect(link.locator("[data-focus-title]")).not.toBeEmpty()
    await expect(link.locator("[data-focus-meta]")).not.toBeEmpty()
    const card = await link.innerText()
    const href = (await link.getAttribute("href"))!
    expect(href).toMatch(/^\/classic\/1(\?room=[a-z-]+|\/proposals\/\d+)$/)

    // A drag toward the past, begun on the mark, carries the mark and its link
    // with it, and opens nothing.
    const before = (await link.boundingBox())!
    const moved = async () => (await link.boundingBox())!.x - before.x
    await page.mouse.down()
    for (let step = 1; step <= 6; step++) await page.mouse.move(found.x + step * 25, found.y)
    await page.mouse.up()
    await expect.poll(moved).toBeGreaterThan(148)
    expect(await moved()).toBeLessThan(152)
    expect(await link.innerText()).toBe(card)
    expect(path(page.url())).toBe("/classic/1/worldline")

    // Its link opens the page it happened on, in a new tab and in this one.
    const [tab] = await Promise.all([page.context().waitForEvent("page"), link.click({modifiers: ["ControlOrMeta"]})])
    await tab.waitForLoadState()
    expect(path(tab.url())).toBe(href)
    await tab.close()

    await link.click()
    await expect.poll(() => path(page.url())).toBe(href)
    await page.goBack()
    await expect(stage).toHaveAttribute("data-worldline-ready", "true")

    // The keyboard reaches a mark too.
    await stage.focus()
    await page.keyboard.press("ArrowLeft")
    await expect(link).toBeVisible()

    // The list has the same events as links.
    await page.locator("#worldline-show-list").click()
    await expect(page).toHaveURL(/\/classic\/1\/worldline\?show=list$/)
    const first = page.locator("#worldline-events li a").first()
    await expect(first).toBeVisible()
    expect(await sideways(page)).toBeLessThanOrEqual(width)
    await page.screenshot({path: info.outputPath(`worldline-list-${width}.png`)})
    const listed = (await first.getAttribute("href"))!
    await first.click()
    await expect.poll(() => path(page.url())).toBe(listed)
    expect(errors).toEqual([])
  })
}
