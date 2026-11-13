import {expect, test, type Locator, type Page} from "@playwright/test"
import {prepareFleet, writeHistory} from "./support/fleet_chain"

// A fleet's Worldline, read signed out: the picture draws a fortnight of the
// fleet's history, the mark pointed at links to the page it happened on, in
// a new tab too, a drag or a scroll over the picture moves it through time,
// Now brings it back, a scroll off the picture or on past now scrolls the
// page, and the list's links open their pages. The first walk asks for less
// motion, so the picture holds still and a mark stays where it was found;
// the second watches it move. The owner's wallet is used by no other spec.
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
// The page scrolls in the app shell's scroller.
const scrolled = (page: Page) => page.locator("#app-shell-scroller").evaluate(element => element.scrollTop)
// The picture as drawn, with the pointer off it.
const drawn = async (page: Page, stage: Locator) => {
  await page.mouse.move(1, 1)
  return stage.screenshot()
}
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

    // Asked for less motion, the picture holds still.
    const still = await drawn(page, stage)
    await page.waitForTimeout(1000)
    expect((await drawn(page, stage)).equals(still)).toBe(true)

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

    // Scrolling over the picture moves it through time too, back and on,
    // and leaves the page where it was.
    const pageTop = await scrolled(page)
    await page.mouse.wheel(0, -100)
    await expect.poll(moved).toBeGreaterThan(248)
    expect(await moved()).toBeLessThan(252)
    await page.waitForTimeout(400)
    await page.mouse.wheel(0, 60)
    await expect.poll(moved).toBeLessThan(192)
    expect(await moved()).toBeGreaterThan(188)
    expect(await scrolled(page)).toBe(pageTop)
    expect(await link.innerText()).toBe(card)

    // Now brings the picture back to the head, and goes.
    const now = page.locator("[data-worldline-now]")
    await expect(now).toBeVisible()
    await now.click()
    await expect(now).toBeHidden()
    await expect.poll(async () => Math.abs(await moved())).toBeLessThan(2)

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
    await expect(now).toBeVisible()
    await page.keyboard.press("End")
    await expect(now).toBeHidden()

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

  // Its own page, so no scroll from earlier steps is still under way.
  test(`off the Worldline, or past now on it, the wheel scrolls the page, at ${width} wide`, async ({page}) => {
    const errors: string[] = []
    page.on("pageerror", error => errors.push(error.message))
    await page.emulateMedia({reducedMotion: "reduce"})
    // A short window gives the page room to scroll.
    await page.setViewportSize({width, height: 520})
    await page.goto("/classic/1/worldline")
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()

    const stage = page.locator("#worldline-stage")
    const now = page.locator("[data-worldline-now]")
    await expect(stage).toHaveAttribute("data-worldline-ready", "true")
    await page.locator("#app-shell-scroller").evaluate(element => element.scrollTo(0, 0))

    // Off the picture the wheel scrolls the page.
    const legend = (await page.locator("#worldline-legend").boundingBox())!
    await page.mouse.move(legend.x + 4, legend.y + legend.height / 2)
    await page.mouse.wheel(0, 120)
    await expect.poll(() => scrolled(page)).toBeGreaterThan(0)

    // On it, at now, scrolling on toward now scrolls the page too, and the
    // picture stays at the head.
    await page.waitForTimeout(600)
    const top = await scrolled(page)
    const over = (await stage.boundingBox())!
    await page.mouse.move(over.x + over.width / 2, (over.y + Math.min(over.y + over.height, 520)) / 2)
    await page.mouse.wheel(0, 120)
    await expect.poll(() => scrolled(page)).toBeGreaterThan(top)
    await expect(now).toBeHidden()
    expect(errors).toEqual([])
  })

  test(`the Worldline moves on its own and still opens the mark pointed at, at ${width} wide`, async ({page}) => {
    const errors: string[] = []
    page.on("pageerror", error => errors.push(error.message))
    await page.setViewportSize({width, height: 900})
    await page.goto("/classic/1/worldline")
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()

    const stage = page.locator("#worldline-stage")
    const link = page.locator("[data-worldline-focus]")
    await expect(stage).toHaveAttribute("data-worldline-ready", "true")

    // The trails keep turning.
    const first = await drawn(page, stage)
    await page.waitForTimeout(1000)
    expect((await drawn(page, stage)).equals(first)).toBe(false)

    // Pointed at, a mark's link holds still on it while the trails ease to a
    // stop, and opens the page it happened on.
    await pointAtMark(page, stage, link)
    const href = (await link.getAttribute("href"))!
    expect(href).toMatch(/^\/classic\/1(\?room=[a-z-]+|\/proposals\/\d+)$/)
    await page.waitForTimeout(700)
    const held = (await link.boundingBox())!
    await page.waitForTimeout(500)
    const later = (await link.boundingBox())!
    expect(Math.hypot(later.x - held.x, later.y - held.y)).toBeLessThan(1)
    expect(await link.getAttribute("href")).toBe(href)
    await link.click()
    await expect.poll(() => path(page.url())).toBe(href)
    expect(errors).toEqual([])
  })
}
