import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {call, prepareFleet, sellKey} from "./support/fleet_chain"

// The workspace's Graph is an endless canvas of the fleet's work, at a
// phone's width and a laptop's: a drag pans it, the wheel zooms it, the
// arrangement moves its cards, pressing a card lights the card's whole line,
// and the keyboard reaches the cards, pans and zooms. The page never scrolls
// sideways.
const fleet = "fibonacci_syndicate"
const me = "0x1111111111111111111111111111111111111111"
const tree = "#workspace-graph-tree"
let made: Record<"goal" | "task" | "other" | "finding" | "fork" | "note", string>

test.beforeAll(() => {
  prepareFleet(fleet)
  sellKey(fleet, me)
  made = JSON.parse(call("tree!", [fleet]))
})

const card = (page: Page, id: string) => page.locator(`${tree} .tree-card[data-id="${id}"]`)

// Where the canvas's world is drawn: its top left corner on screen, and the zoom.
const view = (page: Page) =>
  page.locator(`${tree} [data-tree-front]`).evaluate(el => {
    const [, x, y, zoom] = /translate3d\(([-\d.]+)px, ([-\d.]+)px, 0(?:px)?\) scale\(([\d.]+)\)/.exec(el.style.transform)!
    return {x: Number(x), y: Number(y), zoom: Number(zoom)}
  })

// A point of open ground on the canvas, clear of the cards and the zoom.
const ground = (page: Page) =>
  page.locator(`${tree} [data-tree-surface]`).evaluate(surface => {
    const box = surface.getBoundingClientRect()
    for (let y = box.top + 24; y < Math.min(box.bottom, innerHeight) - 24; y += 16) {
      for (let x = box.left + 24; x < box.right - 24; x += 16) {
        const hit = document.elementFromPoint(x, y)
        if (hit && surface.contains(hit) && !hit.closest(".tree-card, .tree-canvas-zoom")) return {x, y}
      }
    }
    throw new Error("the canvas has no open ground in sight")
  })

const sideways = (page: Page) =>
  page.evaluate(() =>
    [document.documentElement, document.querySelector("#app-shell-scroller")!].map(el => el.scrollWidth - el.clientWidth),
  )

for (const [width, height] of [
  [390, 844],
  [1280, 800],
]) {
  test(`at ${width} wide the Graph pans, zooms, rearranges, lights a line and takes the keyboard`, async ({page}) => {
    const errors: string[] = []
    page.on("pageerror", error => errors.push(error.message))
    await page.setViewportSize({width, height})
    await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
    await page.goto("/syndicate/1/workspace?view=graph")
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
    const surface = page.locator(`${tree} [data-tree-surface]`)
    const level = page.locator(`${tree} [data-tree-zoom-level]`)
    await expect(card(page, made.task)).toBeAttached()
    await surface.scrollIntoViewIfNeeded()
    expect(await sideways(page)).toEqual([0, 0])

    // A drag pans the canvas, and keeps going a little after it is let go.
    const start = await ground(page)
    const before = await view(page)
    await page.mouse.move(start.x, start.y)
    await page.mouse.down()
    await page.mouse.move(start.x - 120, start.y - 60, {steps: 12})
    await page.mouse.up()
    const dragged = await view(page)
    expect(before.x - dragged.x).toBeGreaterThanOrEqual(100)
    expect(before.y - dragged.y).toBeGreaterThanOrEqual(40)
    await expect(page).toHaveURL(/\/syndicate\/1\/workspace\?view=graph$/)

    // The wheel zooms, and the corner says how far.
    const shown = (await level.textContent())!
    const open = await ground(page)
    await page.mouse.move(open.x, open.y)
    await page.mouse.wheel(0, -240)
    await expect(level).not.toHaveText(shown)
    expect((await view(page)).zoom).toBeGreaterThan(before.zoom)

    // Hourly slices, then by author: the cards glide to their authors' bands,
    // and the address keeps both.
    await page.locator(`${tree} [data-tree-zoom="fit"]`).click()
    await page.locator("#workspace-graph-arrange-hour").click()
    await expect(page).toHaveURL(/\?view=graph&every=hour$/)
    await expect(page.locator("#workspace-graph-arrange-hour")).toHaveAttribute("aria-pressed", "true")
    const task = card(page, made.task)
    const placed = () => task.evaluate(el => `${el.dataset.x},${el.dataset.y}`)
    const byTime = await placed()
    await page.locator("#workspace-graph-arrange-author").click()
    await expect(page).toHaveURL(/\?view=graph&arrange=author&every=hour$/)
    await expect(page.locator("#workspace-graph-arrange-author")).toHaveAttribute("aria-pressed", "true")
    await expect(page.locator("#workspace-graph-arrange-hour")).toHaveCount(0)
    await expect.poll(placed).not.toBe(byTime)
    await expect(page.locator(`${tree} [data-tree-headings]`)).toContainText("Key 4")

    // Pressing a card lights it and its whole line, and dims the rest: the
    // goal it delivers on, the finding it produced and the copy made of it,
    // but not the goal's other task. The press is on the card's kind, as its
    // title is a link to the item's page.
    await page.locator(`${tree} [data-tree-zoom="fit"]`).click()
    await expect(task).toBeVisible()
    await task.locator(".tree-card-kind").click()
    await expect(surface).toHaveAttribute("data-lighting", "")
    await expect(task).toHaveAttribute("data-pressed", "")
    await expect(page.locator(`${tree} [data-tree-links] path[data-lit]`)).toHaveCount(3)
    await expect(card(page, made.other)).not.toHaveAttribute("data-lit")
    await expect(page).toHaveURL(/\?view=graph&arrange=author&every=hour$/)

    // From the last arrangement, Tab reaches a card, and Tab again the next;
    // the focused card is lit and outlined. Escape puts the light out, arrow
    // keys pan and plus zooms.
    await page.locator("#workspace-graph-arrange-activity").click()
    await expect(page).toHaveURL(/\?view=graph&arrange=activity&every=hour$/)
    await page.keyboard.press("Tab")
    const focused = page.locator(`${tree} .tree-card:has(.tree-card-title:focus)`)
    await expect(focused).toHaveCount(1)
    const first = await focused.getAttribute("data-id")
    await page.keyboard.press("Tab")
    await expect(focused).not.toHaveAttribute("data-id", first!)
    await expect(focused).toHaveAttribute("data-pressed", "")
    expect(await focused.evaluate(el => getComputedStyle(el).outlineStyle)).toBe("solid")
    await page.keyboard.press("Escape")
    await expect(surface).not.toHaveAttribute("data-lighting")
    await expect(focused).toHaveCount(1)
    const still = await view(page)
    await page.keyboard.press("ArrowRight")
    await expect.poll(async () => (await view(page)).x).toBeLessThan(still.x)
    const zoomed = (await level.textContent())!
    await page.keyboard.press("+")
    await expect(level).not.toHaveText(zoomed)

    expect(await sideways(page)).toEqual([0, 0])
    expect(errors).toEqual([])
  })
}
