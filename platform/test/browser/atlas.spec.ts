import {expect, test, type Locator, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {call, prepareFleet, sellKey} from "./support/fleet_chain"

// A member's Atlas opens on the blocks, drawn on the GPU: a block opens by
// the pointer and the keyboard and the path and Escape go back up, the block
// pointed at or ringed has a card beside it that never covers it and puts
// itself away, and the switch opens the List. Nothing on the page fails.
const fleet = "fibonacci_syndicate"
const me = "0x1111111111111111111111111111111111111111"
const blocks = "#atlas-blocks"

test.use({channel: "chromium"})

test.beforeAll(() => {
  prepareFleet(fleet)
  sellKey(fleet, me)
  call("atlas!", [fleet])
})

const name = (page: Page, text: string) =>
  page.locator(`${blocks} .atlas-blocks__name:not([hidden])`).filter({has: page.getByText(text, {exact: true})})

const centre = async (locator: Locator) => {
  const box = (await locator.boundingBox())!
  return {x: box.x + box.width / 2, y: box.y + box.height / 2}
}

const overlaps = (a: DOMRect | {x: number; y: number; width: number; height: number}, b: typeof a) =>
  a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height

test("a member's Atlas opens on the blocks, which open, go back up, show a card and give way to the List", async ({
  page,
}) => {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  page.on("console", message => {
    if (message.type() === "error") errors.push(message.text())
  })
  await page.setViewportSize({width: 1280, height: 900})
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  await page.goto("/syndicate/1/atlas")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()

  // Blocks open by default, and the GPU draws them.
  await expect(page.locator("#atlas-show-blocks")).toHaveAttribute("aria-current", "page")
  const surface = page.locator(`${blocks} [data-blocks-surface]`)
  await expect(surface).toHaveAttribute("data-blocks-ready", "true")
  await expect(surface).not.toHaveAttribute("data-atlas-still")
  const level = page.locator(`${blocks} [data-blocks-level]`)
  const here = page.locator(`${blocks} [data-blocks-trail] [aria-current=location]`)
  await expect(level).toHaveText("Projects")
  await expect(name(page, "General")).toBeVisible()
  await surface.scrollIntoViewIfNeeded()

  // The pointer opens a project, and the path goes back up.
  const general = await centre(name(page, "General"))
  await page.mouse.click(general.x, general.y)
  await expect(level).not.toHaveText("Projects")
  await expect(page.locator(`${blocks} [data-blocks-trail] li`).nth(1)).toHaveText("General")
  await page.locator(`${blocks} [data-blocks-trail] button`, {hasText: "Fleet"}).click()
  await expect(level).toHaveText("Projects")

  // The keyboard rings a block, opens it, zooms, and goes back up.
  const stage = page.locator("#atlas-blocks-stage")
  await stage.focus()
  await page.keyboard.press("ArrowRight")
  await page.keyboard.press("Enter")
  await expect(here).not.toHaveText("Fleet")
  await expect(level).not.toHaveText("Projects")
  await page.keyboard.press("+")
  await page.keyboard.press("-")
  const card = page.locator(`${blocks} [data-blocks-card]`)
  // Escape puts away the card of the ringed block, then goes up a level at a time.
  for (let tries = 0; tries < 6 && (await level.textContent()) !== "Projects"; tries++) {
    await page.keyboard.press("Escape")
  }
  await expect(level).toHaveText("Projects")
  await expect(stage).toBeFocused()

  // The block pointed at has a card beside it, never over it, and its close
  // button puts it away.
  const harbour = name(page, "Harbour")
  await expect(harbour).toBeVisible()
  const point = await centre(harbour)
  await page.mouse.move(point.x - 5, point.y)
  await page.mouse.move(point.x, point.y)
  await expect(card).toBeVisible()
  await expect(card.locator("[data-card-title]")).toHaveText("Harbour")
  await expect(card.locator("[data-card-kind]")).toHaveText("Project")
  await expect(card.locator("[data-card-counts]")).toContainText("126 changes")
  expect(overlaps((await card.boundingBox())!, (await harbour.boundingBox())!)).toBe(false)
  const box = (await card.boundingBox())!
  const room = (await surface.boundingBox())!
  expect(box.x).toBeGreaterThanOrEqual(room.x)
  expect(box.x + box.width).toBeLessThanOrEqual(room.x + room.width + 1)
  await card.getByRole("button", {name: "Close"}).click()
  await expect(card).toBeHidden()

  // By the keyboard too: the ringed block has its card, and Escape puts it away.
  await stage.focus()
  await page.mouse.move(0, 0)
  await page.keyboard.press("ArrowRight")
  await expect(card).toBeVisible()
  await page.keyboard.press("Escape")
  await expect(card).toBeHidden()
  await expect(level).toHaveText("Projects")

  // The switch opens the List.
  await page.locator("#atlas-show-list").click()
  await expect(page).toHaveURL(/show=list/)
  await expect(page.locator("#atlas-list")).toBeVisible()
  await expect(page.locator("#atlas-show-list")).toHaveAttribute("aria-current", "page")
  await expect(page.locator("#atlas-blocks")).toHaveCount(0)

  expect(errors).toEqual([])
})
