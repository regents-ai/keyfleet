import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {prepareFleet, sayInPublic} from "./support/fleet_chain"

// The guided tour of a fleet's page (KeyfleetWeb.Components.Tour): a first
// visit plays it by itself, Next rings each part in turn, Skip and Done end
// it for good, and Tour plays it again. The tour only points: Buy Key takes
// its press and opens its window whatever step is on show. A holder's tour
// goes on to their Key, their agent and an intro. Every other walk starts
// with both tours marked seen (the configs' storageState); these start with
// nothing kept.
test.use({storageState: {cookies: [], origins: []}})

const me = "0x1111111111111111111111111111111111111111"
// How far a ring stands outside its part: the room left round the part and
// the ring's own thickness (tour/place.ts).
const RING_OUTSIDE = 6 + 2

const visitor: [string, string][] = [
  ["Fleet", ".fleet-bar__title h1"],
  ["Chat", "#fleet-tab-hall"],
  ["Workspace", "#fleet-tab-workspace"],
  ["Treasury", "#fleet-tab-treasury"],
  ["Keys", "#fleet-tab-keys"],
  ["Proposals", "#fleet-tab-proposals"],
  ["Account", '#account-control [data-account-target="sign-in"]'],
  ["Key", "#fleet-get-key"],
]

const holder: [string, string | null][] = [
  ...visitor.slice(0, 6),
  ["Your Key", "#fleet-entry-cards"],
  ["Agent", "#fleet-pair"],
  ["Skills", null],
  ["Schedule", null],
  ["Intro", "#fleet-room-welcome"],
]

test.beforeAll(() => {
  prepareFleet("fleet_tech_classic")
  prepareFleet("fibonacci_cascade")
})

async function open(page: Page, path: string) {
  await page.goto(path)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
}

const card = (page: Page) => page.locator(".tour__card")
const title = (page: Page) => page.locator(".tour [data-tour-title]")
const next = (page: Page) => page.locator(".tour [data-tour-next]")

// Where the ring and the card stand against the step's part: how far the ring
// is from standing RING_OUTSIDE round the part on every side (0 when it does),
// whether the card covers the part, whether it lies wholly on the screen, and
// whether every Buy Key and wallet step on the screen is what a press at its
// middle reaches.
function standing(page: Page, selector: string | null) {
  return page.evaluate(
    ([selector, outside]) => {
      const box = (el: Element) => {
        if (!/^H[1-6]$/.test(el.tagName)) return el.getBoundingClientRect()
        const words = document.createRange()
        words.selectNodeContents(el)
        return words.getBoundingClientRect()
      }
      const ring = [...document.querySelectorAll(".tour__edge > .tour__piece")].map(piece => piece.getBoundingClientRect())
      const drawn = ring.filter(line => line.width > 0 && line.height > 0)
      const shown = document.querySelector(".tour__card")!.getBoundingClientRect()
      const onScreen = shown.left >= 0 && shown.top >= 0 && shown.right <= innerWidth && shown.bottom <= innerHeight
      const inReach = [...document.querySelectorAll("#fleet-get-key, #shell-get-key, [data-onchain-step]")]
        .map(control => [control, control.getBoundingClientRect()] as const)
        .filter(([, at]) => at.width > 0 && at.top >= 0 && at.left >= 0 && at.bottom <= innerHeight && at.right <= innerWidth)
        .every(([control, at]) => control.contains(document.elementFromPoint(at.x + at.width / 2, at.y + at.height / 2)))
      const overflow = document.documentElement.scrollWidth > innerWidth

      if (selector === null) {
        const middle = Math.abs(shown.x + shown.width / 2 - innerWidth / 2)
        return {ringOff: drawn.length, covers: false, onScreen, inReach, overflow, middle}
      }
      const part = box(document.querySelector(selector)!)
      const outer = {
        left: Math.min(...ring.map(line => line.left)),
        top: Math.min(...ring.map(line => line.top)),
        right: Math.max(...ring.map(line => line.right)),
        bottom: Math.max(...ring.map(line => line.bottom)),
      }
      const ringOff = Math.max(
        Math.abs(outer.left - (part.left - outside)),
        Math.abs(outer.top - (part.top - outside)),
        Math.abs(outer.right - (part.right + outside)),
        Math.abs(outer.bottom - (part.bottom + outside)),
      )
      const covers =
        shown.left < part.right && part.left < shown.right && shown.top < part.bottom && part.top < shown.bottom
      return {ringOff, covers, onScreen, inReach, overflow, middle: 0}
    },
    [selector, RING_OUTSIDE] as const,
  )
}

// Walks a tour from its first step to Done, checking each step as it goes.
async function walk(page: Page, steps: [string, string | null][], {still = false} = {}) {
  for (const [index, [name, selector]] of steps.entries()) {
    await expect(title(page)).toHaveText(name)
    // With less motion asked for, the ring is round its part on the next
    // frame, with no glide to it.
    if (still) {
      await page.evaluate(() => new Promise(done => requestAnimationFrame(() => requestAnimationFrame(done))))
      expect((await standing(page, selector)).ringOff).toBeLessThanOrEqual(1.5)
    }
    await expect.poll(async () => (await standing(page, selector)).ringOff).toBeLessThanOrEqual(1.5)
    const now = await standing(page, selector)
    expect(now.covers).toBe(false)
    expect(now.onScreen).toBe(true)
    expect(now.overflow).toBe(false)
    expect(now.inReach).toBe(true)
    await expect(next(page)).toHaveText(index === steps.length - 1 ? "Done" : "Next")
    await next(page).click()
  }
  await expect(card(page)).toBeHidden()
}

const seen = (page: Page) =>
  page.evaluate(() => [localStorage.getItem("keyfleet:tour:visitor"), localStorage.getItem("keyfleet:tour:holder")])

const ringed = (page: Page) => page.evaluate(() => document.activeElement?.matches(":focus-visible") ?? false)

// The Skills step's Copy, pressed from the keyboard, puts the message for the
// person's agent on the clipboard, naming where the skill is. Focus stays on
// it in the card, and its answer keeps the button's size.
async function copiesTheSkill(page: Page) {
  const copy = page.locator(".tour [data-tour-copy]")
  await expect(copy).toBeVisible()
  const before = await copy.boundingBox()
  await copy.focus()
  await page.keyboard.press("Enter")
  await expect(copy).toHaveAttribute("data-copy-state", "copied")
  await expect(copy).toBeFocused()
  expect(await copy.boundingBox()).toEqual(before)
  const skill = `${new URL(page.url()).origin}/skill.md`
  expect(await page.evaluate(() => navigator.clipboard.readText())).toContain(skill)
}

test("a first visit plays the visitor's tour, ringing each part in turn, and Done ends it for good", async ({page}) => {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  await page.setViewportSize({width: 1280, height: 800})
  await open(page, "/classic/1")

  await expect(card(page)).toBeVisible()
  await expect(next(page)).toBeFocused()
  await walk(page, visitor)
  expect(await seen(page)).toEqual(["seen", null])

  await page.reload()
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  await expect(card(page)).toBeHidden()
  expect(errors).toEqual([])
})

test("a tour that plays by itself rings Next only once a key is pressed", async ({page}) => {
  await open(page, "/classic/1")
  await expect(next(page)).toBeFocused()
  expect(await ringed(page)).toBe(false)

  await page.keyboard.press("Shift+Tab")
  await page.keyboard.press("Tab")
  await expect(next(page)).toBeFocused()
  expect(await ringed(page)).toBe(true)
})

test("Skip and Escape end the tour, a reload leaves it ended, and Tour plays it again", async ({page}) => {
  await open(page, "/classic/1")
  await expect(title(page)).toHaveText("Fleet")
  await next(page).click()
  await expect(title(page)).toHaveText("Chat")
  await page.locator(".tour [data-tour-skip]").click()
  await expect(card(page)).toBeHidden()
  expect(await seen(page)).toEqual(["seen", null])

  await page.reload()
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  await expect(card(page)).toBeHidden()

  const tour = page.locator("#fleet-tour-start")
  await tour.click()
  await expect(card(page)).toBeVisible()
  await expect(title(page)).toHaveText("Fleet")
  await expect(next(page)).toBeFocused()
  await page.keyboard.press("Escape")
  await expect(card(page)).toBeHidden()
  await expect(tour).toBeFocused()
})

test("Buy Key takes its press while the tour shows, at the first step and at its own", async ({page}) => {
  await page.setViewportSize({width: 1280, height: 800})
  await open(page, "/classic/1")
  await expect(title(page)).toHaveText("Fleet")

  const buy = page.locator("#fleet-get-key")
  await buy.click()
  const window = page.locator("dialog#buy-key")
  await expect(window.locator("#buy-key-title")).toBeVisible()
  // Escape closes the window, not the tour under it.
  await page.keyboard.press("Escape")
  await expect(window).toHaveCount(0)
  await expect(title(page)).toHaveText("Fleet")

  for (const [name] of visitor.slice(0, -1)) {
    await expect(title(page)).toHaveText(name)
    await next(page).click()
  }
  await expect(title(page)).toHaveText("Key")
  await buy.click()
  await expect(window.locator("#buy-key-title")).toBeVisible()
  await expect(card(page)).toBeAttached()
})

test("a holder's tour goes on to their Key, their agent, its skill, its daily run and an intro", async ({page}) => {
  // A Key, and the fleet's rooms with it, so the intro has its room to point at.
  sayInPublic("fibonacci_cascade", me, "Hello")
  await page.context().grantPermissions(["clipboard-read", "clipboard-write"])
  await page.setViewportSize({width: 1280, height: 800})
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  await open(page, "/cascade/1")

  await expect(card(page)).toBeVisible()
  for (const [index, [name, selector]] of holder.entries()) {
    await expect(title(page)).toHaveText(name)
    await expect.poll(async () => (await standing(page, selector)).ringOff).toBeLessThanOrEqual(1.5)
    const copy = page.locator(".tour [data-tour-copy]")
    if (name === "Skills") await copiesTheSkill(page)
    else await expect(copy).toBeHidden()
    const now = await standing(page, selector)
    expect(now.covers).toBe(false)
    expect(now.onScreen).toBe(true)
    // Mark present, a wallet step, stays in reach whatever step is on show.
    expect(now.inReach).toBe(true)
    // A step that points at nothing has its card across the middle of the screen.
    if (selector === null) expect(now.middle).toBeLessThanOrEqual(1)
    if (index < holder.length - 1) await next(page).click()
  }
  await next(page).click()
  await expect(card(page)).toBeHidden()
  expect(await seen(page)).toEqual([null, "seen"])

  await page.locator("#fleet-tour-start").click()
  await expect(title(page)).toHaveText("Fleet")
})

test("with less motion asked for, and on a 320 wide phone, the card stays on the screen and the ring is simply there", async ({
  page,
}) => {
  await page.emulateMedia({reducedMotion: "reduce"})
  await page.setViewportSize({width: 320, height: 640})
  await open(page, "/classic/1")

  await expect(card(page)).toBeVisible()
  const shown = await page.evaluate(() => {
    const steps = [...document.querySelectorAll<HTMLTemplateElement>("template[data-tour-steps='visitor']")]
      .flatMap(list => [...list.content.querySelectorAll<HTMLElement>("[data-step]")])
      .filter(step => {
        const part = document.querySelector(step.dataset.target!)
        return part !== null && part.getClientRects().length > 0
      })
    return steps.map(step => [step.dataset.title!, step.dataset.target!] as [string, string])
  })
  expect(shown.length).toBeGreaterThan(5)
  await walk(page, shown, {still: true})
})
