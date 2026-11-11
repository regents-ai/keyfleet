import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {prepareFleet, sayInPublic, sellKey} from "./support/fleet_chain"

// A fleet page's layout: the hall's columns scroll inside the fleet's box and
// never run past its edge, the way in sits in the bar above the tabs, and it
// is a filled Tangerine button with Charcoal words in both themes.
const fleet = "fleet_tech_classic"

test.beforeAll(() => {
  prepareFleet(fleet)
})

async function openFleet(page: Page) {
  await page.goto(`/classic/1`)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  await expect(page.locator("#fleet-hall")).toBeVisible()
}

const bottoms = (page: Page) =>
  page.evaluate(() => {
    const bottom = (selector: string) => document.querySelector(selector)!.getBoundingClientRect().bottom
    return {
      view: bottom("#fleet-view"),
      hall: bottom("#fleet-hall"),
      columns: [...document.querySelectorAll("#fleet-hall > *")].map(column => column.getBoundingClientRect().bottom),
    }
  })

for (const [width, height] of [
  [1440, 900],
  [1280, 700],
  [1280, 560],
]) {
  test(`at ${width}×${height} the hall ends inside the fleet's box`, async ({page}) => {
    await page.setViewportSize({width, height})
    await openFleet(page)

    const {view, hall, columns} = await bottoms(page)
    expect(hall).toBeLessThanOrEqual(view)
    for (const column of columns) expect(column).toBeLessThanOrEqual(view)
  })
}

test("on a tall screen the hall fills the box to the screen's foot and scrolls on its own", async ({page}) => {
  await page.setViewportSize({width: 1440, height: 900})
  await openFleet(page)

  const {view, hall} = await bottoms(page)
  // The page's own margin is all that lies under the box.
  const margin = await page.locator("#route-content").evaluate(el => parseFloat(getComputedStyle(el).paddingBottom))
  expect(Math.abs(900 - margin - view)).toBeLessThanOrEqual(1)
  expect(view - hall).toBeLessThanOrEqual(2)
  // The page itself scrolls only as far as the footer after it.
  const below = await page.locator("#app-shell-scroller").evaluate(el => ({
    extra: el.scrollHeight - el.clientHeight,
    footer: el.querySelector(":scope > .regent-footer")!.getBoundingClientRect().height,
  }))
  expect(Math.abs(below.extra - below.footer)).toBeLessThanOrEqual(1)
})

// The window never scrolls under an app page: the page scrolls on its own
// under the header, and the footer is the last thing in it, reached by
// scrolling the page from anywhere on it.
for (const [width, height] of [
  [1440, 900],
  [390, 844],
]) {
  test(`at ${width}×${height} the page scrolls once, to the footer at its end`, async ({page}) => {
    await page.setViewportSize({width, height})
    await page.goto(`/classic/1/workspace`)
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()

    expect(await page.evaluate(() => document.documentElement.scrollHeight)).toBeLessThanOrEqual(height)
    await expect(page.locator("body > .regent-footer")).toHaveCount(0)
    const footer = page.locator("#app-shell-scroller > .regent-footer")
    await expect(footer).toHaveCount(1)

    await page.locator("#app-shell-scroller").evaluate(el => el.scrollTo(0, el.scrollHeight))
    const box = (await footer.boundingBox())!
    expect(Math.abs(box.y + box.height - height)).toBeLessThanOrEqual(1)
  })
}

// The footer is one short row. A Key holder's channel list holds every room
// and runs past its foot: a "…" stands there until the last room shows, and
// scrolling on past the last room carries on down the page to the footer.
// Scrolling over the left menu moves the page too. Sean, 30 October 2026. The
// Key is sold, and the rooms opened, on a fleet of its own, so the Classic
// fleet stays unsold. The new holder's setup list stands above the hall, so
// the walk brings the channel list into view before scrolling over it.
test("the footer is one short row, reached from the channel list and the left menu", async ({page}) => {
  prepareFleet("fibonacci_cascade")
  sayInPublic("fibonacci_cascade", "0x1111111111111111111111111111111111111111", "Hello.")
  await page.setViewportSize({width: 1440, height: 800})
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  await page.goto(`/cascade/1`)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")

  const scroller = page.locator("#app-shell-scroller")
  const footer = scroller.locator(":scope > .regent-footer")
  expect((await footer.boundingBox())!.height).toBeLessThanOrEqual(56)

  const channels = page.locator("#fleet-channels")
  const read = () =>
    page.evaluate(() => {
      const list = document.querySelector("#fleet-channels")!
      const shell = document.querySelector("#app-shell-scroller")!
      return {
        hidden: list.scrollHeight - list.clientHeight - list.scrollTop,
        more: getComputedStyle(list, "::after").opacity,
        below: shell.scrollHeight - shell.clientHeight - shell.scrollTop,
      }
    })
  const before = await read()
  expect(before.hidden).toBeGreaterThan(0)
  expect(before.more).toBe("1")

  await channels.scrollIntoViewIfNeeded()
  const box = (await channels.boundingBox())!
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
  await expect(async () => {
    await page.mouse.wheel(0, 200)
    const after = await read()
    expect(after.hidden).toBeLessThanOrEqual(1)
    expect(after.more).toBe("0")
    expect(after.below).toBeLessThanOrEqual(1)
  }).toPass()

  await scroller.evaluate(el => el.scrollTo(0, 0))
  await page.locator("#shell-sidebar").evaluate(el => el.scrollTo(0, el.scrollHeight))
  const sidebar = (await page.locator("#shell-sidebar").boundingBox())!
  await page.mouse.move(sidebar.x + sidebar.width / 2, sidebar.y + sidebar.height - 20)
  await page.mouse.wheel(0, 400)
  await expect.poll(() => scroller.evaluate(el => el.scrollHeight - el.clientHeight - el.scrollTop)).toBeLessThanOrEqual(1)
})

// A list with every room in view never shows the "…".
test("a channel list with every room in view shows no \"…\"", async ({page}) => {
  await page.setViewportSize({width: 1440, height: 900})
  await openFleet(page)

  const list = await page.locator("#fleet-channels").evaluate(el => ({
    hidden: el.scrollHeight - el.clientHeight,
    more: getComputedStyle(el, "::after").opacity,
  }))
  expect(list).toEqual({hidden: 0, more: "0"})
})

for (const scheme of ["light", "dark"] as const) {
  test(`"Purchase Key" is filled Tangerine with Charcoal words in ${scheme}`, async ({page, baseURL}) => {
    // The theme the visitor chose, as the switch writes it.
    await page.context().addCookies([{name: "regent_theme", value: scheme, url: baseURL!}])
    await openFleet(page)
    await expect(page.locator("html")).toHaveAttribute("data-theme", scheme)

    const button = page.locator("#fleet-get-key")
    await expect(button).toHaveText(/Join this Keyfleet by purchasing the next Key: [0-9.,]+ USDC/)
    const paint = await button.evaluate(element => ({
      fill: getComputedStyle(element, "::before").backgroundColor,
      ink: getComputedStyle(element).color,
    }))
    expect(paint).toEqual({fill: "rgb(255, 91, 25)", ink: "rgb(22, 22, 22)"})
  })
}

// The way in sits in the fleet's bar, above its tabs, and opens the "Buy Key"
// window, as the header's "Purchase Key" does (Sean, 20 October 2026).
test("the way in sits above the tabs and opens the Buy Key window, as Purchase Key does", async ({page}) => {
  await page.setViewportSize({width: 1440, height: 900})
  await openFleet(page)

  const [entry, tabs] = await Promise.all(["#fleet-entry", "#fleet-tabs"].map(id => page.locator(id).boundingBox()))
  expect(entry!.y + entry!.height).toBeLessThanOrEqual(tabs!.y + 1)
  expect(await page.locator("header.fleet-bar #fleet-entry + #fleet-tabs").count()).toBe(1)

  for (const opener of ["#fleet-get-key", "#shell-get-key"]) {
    await page.locator(opener).click()
    const window = page.locator("dialog#buy-key")
    await expect(window).toBeVisible()
    await expect(window.locator("#buy-key-button")).toBeVisible()
    await window.locator("#buy-key-close").click()
    await expect(window).toHaveCount(0)
  }
})

// A holder's Keys show as cards twice the old size (Sean, 20 October 2026). A
// card names its Key under the pointer once its picture is drawn; until then it
// names its Key in its middle at all times. Test fleets have no deck, so their
// cards have no picture. The Key is sold on a fleet of its own, so the Classic
// fleet the other walks open stays as they expect it.
test("a holder's cards are 96 wide, and one with no picture yet names its Key at all times", async ({page}) => {
  prepareFleet("fibonacci_cascade")
  sellKey("fibonacci_cascade", "0x1111111111111111111111111111111111111111")
  await page.setViewportSize({width: 1440, height: 900})
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  await page.goto(`/cascade/1`)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()

  const card = page.locator("#fleet-entry-cards .fleet-entry__card").first()
  await expect(card).toBeVisible()
  const blank = card.locator(".fleet-entry__blank")
  await expect(blank).toHaveCount(1)
  expect(Math.round((await blank.boundingBox())!.width)).toBe(96)
  const name = card.locator(".fleet-entry__name")
  await expect(name).toHaveText(/^Key [0-9,]+$/)
  await expect(name).toHaveCSS("opacity", "1")
})
