import {expect, test, type Page} from "@playwright/test"
import {prepareFleet, publishPage, takeBackPublic} from "./support/fleet_chain"
import {atRest} from "./support/first_visit"

// Under the homepage's hero, Recent: what Classic #1's Keys made public,
// newest first, each a plain link to its place in the fleet's Public place,
// and Notebook: the newest notebook page made public. Both arrive with the
// fleet's reading while the page is open, and neither moves Buy Key or the
// figures. From four things, Recent slides leftward: a pointer over it pauses
// it, keyboard focus in it stops it at its first link, and Tab meets each
// thing once. With less motion it stands still. Nothing scrolls the page
// sideways. This runs with the chain to deploy Classic, whose pages are then
// open, and takes back what it made public.
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

test("Recent and Notebook arrive under the hero, slide from four things, pause and stop for a person", async ({page}) => {
  await page.setViewportSize({width: 1280, height: 800})
  await openHome(page)
  await expect(page.locator("#home-recent, #home-notebook")).toHaveCount(0)
  await atRest(page)
  const buy = await box(page, "#home-buy-key")
  const facts = await box(page, "#home-classic-facts")

  // Two pages made public: both stand still, and the newest is Notebook's.
  publishPage(classic, 3)
  const newest = publishPage(classic, 4)
  await expect(page.locator("#home-recent-list > li")).toHaveCount(2)
  await expect(page.locator("#home-recent-band")).not.toHaveAttribute("data-slides")
  await expect(page.locator("#home-recent-band .rl-ticker__list")).toHaveCount(1)
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

  // Buy Key and the figures stay where they were, on the first screen.
  expect(await box(page, "#home-buy-key")).toEqual(buy)
  expect(await box(page, "#home-classic-facts")).toEqual(facts)
  expect(buy.bottom).toBeLessThanOrEqual(800)
  expect(facts.bottom).toBeLessThanOrEqual(800)
  expect(await sideways(page)).toBe(0)

  // A pointer over it pauses it where it is; leaving lets it go on.
  await page.locator("#home-recent-band").hover()
  await expect.poll(() => motion(page)).toEqual(["paused"])
  await page.mouse.move(0, 0)
  await expect.poll(() => motion(page)).toEqual(["running"])

  // Keyboard focus stops it at its first link; Tab reaches each thing once,
  // in view, then Notebook's link, never the copy.
  await page.locator("#home-buy-key").focus()
  for (const [index, link] of (await page.locator("#home-recent-list a").all()).entries()) {
    await page.keyboard.press("Tab")
    await expect(link, `thing ${index + 1} has focus`).toBeFocused()
    expect(await motion(page)).toEqual([])
    const shown = await link.evaluate(element => {
      const view = element.closest(".rl-ticker")!.getBoundingClientRect()
      const {left, right} = element.getBoundingClientRect()
      return Math.min(right, view.right) - Math.max(left, view.left)
    })
    expect(shown, `thing ${index + 1} is in view`).toBeGreaterThan(32)
  }
  await page.keyboard.press("Tab")
  await expect(page.locator("#home-notebook-open")).toBeFocused()
  await expect.poll(() => motion(page)).toEqual(["running"])

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

test("with less motion Recent stands still, the newest three in one line, at 1280 and 390", async ({page}) => {
  await page.emulateMedia({reducedMotion: "reduce"})

  for (const size of [{width: 1280, height: 800}, {width: 390, height: 844}]) {
    await page.setViewportSize(size)
    await openHome(page)
    await expect(page.locator("#home-recent-list > li")).toHaveCount(5)
    expect(await motion(page)).toEqual([])
    await expect(page.locator("#home-recent-list > li:visible")).toHaveCount(3)
    await expect(page.locator("#home-recent-band .rl-ticker__list + .rl-ticker__list")).toBeHidden()
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
