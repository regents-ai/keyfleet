import {expect, test, type Page} from "@playwright/test"
import {prepareFleet, publishPage, takeBackPublic} from "./support/fleet_chain"
import {atRest} from "./support/first_visit"

// Under the homepage's hero, Recent: what Classic #1's Keys made public,
// newest first, each a plain link to its place in the fleet's Public place,
// and Notebook: the newest notebook page made public. Both arrive with the
// fleet's reading while the page is open, and neither moves Buy Key or the
// figures. From four things, Recent slides leftward: a pointer over it pauses
// it, Pause beside its label stops it until pressed again, keyboard focus in
// it stops it and brings each link wholly into view, and Tab meets each thing
// once. With less motion it stands still, with no Pause. Nothing scrolls the
// page sideways. This runs with the chain to deploy Classic, whose pages are
// then open, and takes back what it made public.
const classic = "fleet_tech_classic"
const place = /^\/classic\/1\/workspace\?place=public#public-[0-9a-f-]{36}$/

test.beforeAll(() => {
  prepareFleet(classic)
})

test.afterAll(() => {
  takeBackPublic(classic)
})

async function openHome(page: Page) {
  await page.goto("/")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
}

const box = (page: Page, selector: string) =>
  page.locator(selector).evaluate(element => {
    const {top, bottom} = element.getBoundingClientRect()
    return {top: top + scrollY, bottom: bottom + scrollY}
  })

const sideways = (page: Page) =>
  page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)

// The play states of the band's motion: none while it stands still.
const motion = (page: Page) =>
  page.locator("#home-recent-band .rl-ticker__track").evaluate(track => track.getAnimations().map(animation => animation.playState))

// Where the line stands now.
const position = (page: Page) =>
  page.locator("#home-recent-band .rl-ticker__track").evaluate(track => getComputedStyle(track).transform)

test("Recent and Notebook arrive under the hero, slide from four things, pause and stop for a person", async ({page}) => {
  await page.setViewportSize({width: 1280, height: 800})
  await openHome(page)
  await expect(page.locator("#home-recent, #home-notebook")).toHaveCount(0)
  await atRest(page)
  const buy = await box(page, "#home-buy-key")
  const facts = await box(page, "#home-classic-facts")
  const steps = await box(page, "#home-steps")

  // Two pages made public: both stand still, with no Pause, and the newest is
  // Notebook's.
  publishPage(classic, 3)
  const newest = publishPage(classic, 4)
  await expect(page.locator("#home-recent-list > li")).toHaveCount(2)
  await expect(page.locator("#home-recent-band")).not.toHaveAttribute("data-slides")
  await expect(page.locator("#home-recent-band .rl-ticker__list")).toHaveCount(1)
  await expect(page.locator("#home-recent-pause")).toHaveCount(0)
  expect(await motion(page)).toEqual([])
  await expect(page.locator("#home-notebook-open")).toHaveAttribute("href", newest)
  await expect(page.locator("#home-notebook")).toContainText("Key 4")

  // Five: they slide, held twice, the copy hidden from screen readers and Tab.
  for (const key of [5, 6, 7]) publishPage(classic, key)
  await expect(page.locator("#home-recent-list > li")).toHaveCount(5)
  await expect(page.locator("#home-recent-band")).toHaveAttribute("data-slides", "")
  const copy = page.locator("#home-recent-band .rl-ticker__list + .rl-ticker__list")
  await expect(copy).toHaveAttribute("aria-hidden", "true")
  await expect(copy).toHaveAttribute("inert", "")
  await expect(copy.locator("li")).toHaveCount(5)
  await expect(copy.locator("[id]")).toHaveCount(0)
  await expect.poll(() => motion(page)).toEqual(["running"])

  for (const link of await page.locator("#home-recent-list a").all()) {
    expect(await link.getAttribute("href")).toMatch(place)
    expect(await link.getAttribute("data-phx-link")).toBeNull()
  }

  // Buy Key, the figures and the steps stay where they were, Buy Key and the
  // figures on the first screen.
  expect(await box(page, "#home-buy-key")).toEqual(buy)
  expect(await box(page, "#home-classic-facts")).toEqual(facts)
  expect(await box(page, "#home-steps")).toEqual(steps)
  expect(buy.bottom).toBeLessThanOrEqual(800)
  expect(facts.bottom).toBeLessThanOrEqual(800)
  expect(await sideways(page)).toBe(0)

  // A pointer over it pauses it where it is; leaving lets it go on.
  await page.locator("#home-recent-band").hover()
  await expect.poll(() => motion(page)).toEqual(["paused"])
  await page.mouse.move(0, 0)
  await expect.poll(() => motion(page)).toEqual(["running"])

  // Pause stops it where it is, and it stays stopped, Pause now Play; Play,
  // from the keyboard, lets it go on.
  const pause = page.locator("#home-recent-pause")
  await expect(pause).toHaveAccessibleName("Pause")
  const target = await pause.boundingBox()
  expect(target!.width).toBeGreaterThanOrEqual(24)
  expect(target!.height).toBeGreaterThanOrEqual(24)
  await pause.click()
  await page.mouse.move(0, 0)
  await expect(pause).toHaveAccessibleName("Play")
  await expect(pause.locator("span:visible")).toHaveText("Play")
  await expect.poll(() => motion(page)).toEqual(["paused"])
  const stopped = await position(page)
  await page.waitForTimeout(400)
  expect(await position(page)).toBe(stopped)
  await pause.focus()
  await page.keyboard.press("Space")
  await expect(pause).toHaveAccessibleName("Pause")
  await expect.poll(() => motion(page)).toEqual(["running"])
  await expect.poll(() => position(page)).not.toBe(stopped)
  expect(await box(page, "#home-steps")).toEqual(steps)

  // Tab meets Pause before the first thing. Keyboard focus stops the line;
  // Tab reaches each thing once, wholly in view, then Notebook's link, never
  // the copy, and the line slides again from its start.
  await page.locator("#home-buy-key").focus()
  await page.keyboard.press("Tab")
  await expect(pause).toBeFocused()
  for (const [index, link] of (await page.locator("#home-recent-list a").all()).entries()) {
    await page.keyboard.press("Tab")
    await expect(link, `thing ${index + 1} has focus`).toBeFocused()
    expect(await motion(page)).toEqual([])
    await expect
      .poll(
        () =>
          link.evaluate(element => {
            const view = element.closest(".rl-ticker")!.getBoundingClientRect()
            const {left, right} = element.getBoundingClientRect()
            return left >= view.left - 0.5 && right <= view.right + 0.5
          }),
        {message: `thing ${index + 1} is wholly in view`},
      )
      .toBe(true)
  }
  await page.keyboard.press("Tab")
  await expect(page.locator("#home-notebook-open")).toBeFocused()
  await expect.poll(() => motion(page)).toEqual(["running"])
  expect(await page.locator("#home-recent-band").evaluate(band => band.scrollLeft)).toBe(0)

  // On a phone nothing scrolls sideways either.
  await page.setViewportSize({width: 390, height: 844})
  expect(await sideways(page)).toBe(0)
  await page.setViewportSize({width: 1280, height: 800})

  // A thing opens its place in the Public place.
  await page.locator("#home-recent-band").hover()
  await expect.poll(() => motion(page)).toEqual(["paused"])
  const first = page.locator("#home-recent-list a").first()
  const href = await first.getAttribute("href")
  await first.click()
  await expect(page).toHaveURL(href!)
  await expect(page.locator(`#${href!.split("#")[1]}`)).toBeVisible()
})

test("with less motion Recent stands still, the newest three in one line, with no Pause, at 1280 and 390", async ({page}) => {
  await page.emulateMedia({reducedMotion: "reduce"})

  for (const size of [{width: 1280, height: 800}, {width: 390, height: 844}]) {
    await page.setViewportSize(size)
    await openHome(page)
    await expect(page.locator("#home-recent-list > li")).toHaveCount(5)
    expect(await motion(page)).toEqual([])
    await expect(page.locator("#home-recent-list > li:visible")).toHaveCount(3)
    await expect(page.locator("#home-recent-band .rl-ticker__list + .rl-ticker__list")).toBeHidden()
    await expect(page.locator("#home-recent-pause")).toBeHidden()
    const transform = await page.locator("#home-recent-band .rl-ticker__track").evaluate(track => getComputedStyle(track).transform)
    expect(transform).toBe("none")
    expect(await sideways(page)).toBe(0)
  }
})

test("once everything is taken back, Recent and Notebook leave the page", async ({page}) => {
  await openHome(page)
  await expect(page.locator("#home-recent-list > li")).toHaveCount(5)
  takeBackPublic(classic)
  await expect(page.locator("#home-recent, #home-notebook")).toHaveCount(0)
  await expect(page.locator(".rl-recent")).toHaveCount(0)
})
