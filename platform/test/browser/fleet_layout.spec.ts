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
  test(`the fleet's "Buy Key" is filled Tangerine with Charcoal words in ${scheme}, the Key on offer beside it`, async ({page, baseURL}) => {
    // The theme the visitor chose, as the switch writes it.
    await page.context().addCookies([{name: "regent_theme", value: scheme, url: baseURL!}])
    await openFleet(page)
    await expect(page.locator("html")).toHaveAttribute("data-theme", scheme)

    const button = page.locator("#fleet-get-key")
    await expect(button).toHaveText("Buy Key")
    await expect(page.locator("#fleet-buy-offer")).toHaveText(/^Key [0-9,]+ · [0-9.,]+ USDC$/)
    const paint = await button.evaluate(element => ({
      fill: getComputedStyle(element, "::before").backgroundColor,
      ink: getComputedStyle(element).color,
    }))
    expect(paint).toEqual({fill: "rgb(255, 91, 25)", ink: "rgb(22, 22, 22)"})
  })
}

// The way in sits in the fleet's bar, above its tabs, and opens the "Buy Key"
// window, as the header's "Buy Key" does (Sean, 20 October 2026).
test("the way in sits above the tabs and opens the Buy Key window, as the header's Buy Key does", async ({page}) => {
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

// On a phone the fleet's tabs and the feed's channels each scroll sideways in
// their own row. At rest no item is cut part way: each stands whole in the
// row's clear box (the row less the fade at an edge with more past it) or lies
// wholly past it, under the fade or out of the row. The selected item stands
// whole, so does an item reached from the keyboard, every item is a finger
// tall, and the page never scrolls sideways.
// The rows are read with the channels' rooms in, on a fleet of their own.
const rowsAtRest = (page: Page) =>
  page.evaluate(() =>
    ["#fleet-tabs", "#fleet-channels"].flatMap(id => {
      const row = document.querySelector<HTMLElement>(id)
      if (!row) return []
      const box = row.getBoundingClientRect()
      const style = getComputedStyle(row)
      const start = box.left + parseFloat(style.getPropertyValue("--fleet-fade-start"))
      const end = box.right - parseFloat(style.getPropertyValue("--fleet-fade-end"))
      return [[...row.querySelectorAll<HTMLElement>("a, button")].map(item => {
        const {left, right, height} = item.getBoundingClientRect()
        const whole = left >= start - 0.5 && right <= end + 0.5
        const past = right <= start + 0.5 || left >= end - 0.5
        const chosen = item.getAttribute("aria-current") === "page" ? 2 : item.getAttribute("aria-pressed") === "true" ? 1 : 0
        const focused = item === document.activeElement
        return {item: `${id} ${item.id}`, rests: whole || past, chosen, focused, whole, height}
      })]
    }),
  )

// The open tab or room is a row's chosen item, else its pressed channel.
const chosenWhole = async (page: Page) =>
  (await rowsAtRest(page)).map(row => [...row].sort((a, b) => b.chosen - a.chosen)[0].whole)

async function expectRowsAtRest(page: Page, width: number) {
  await expect
    .poll(async () => (await rowsAtRest(page)).flat().filter(item => !item.rests).map(item => item.item))
    .toEqual([])
  for (const item of (await rowsAtRest(page)).flat()) expect(item.height, item.item).toBeGreaterThanOrEqual(44)
  const sideways = await page.evaluate(() => {
    const scroller = document.querySelector("#app-shell-scroller")!
    return [document.documentElement.scrollWidth, scroller.scrollWidth - scroller.clientWidth]
  })
  expect(sideways).toEqual([width, 0])
}

for (const width of [390, 320]) {
  test(`at ${width} wide the tabs and channels rest with no item cut and the chosen one whole`, async ({page}) => {
    prepareFleet("fibonacci_cascade")
    sayInPublic("fibonacci_cascade", "0x1111111111111111111111111111111111111111", "Hello.")
    await page.setViewportSize({width, height: 844})
    await page.goto(`/cascade/1`)
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
    await expect(page.locator("#fleet-hall")).toBeVisible()

    const rows = ["#fleet-tabs", "#fleet-channels"].map(id => page.locator(id))
    for (const row of rows) expect(await row.evaluate(el => el.scrollWidth > el.clientWidth)).toBe(true)
    await expectRowsAtRest(page, width)
    expect(await chosenWhole(page)).toEqual([true, true])

    // A swipe part way comes to rest on a whole item; so does the row's end.
    for (const row of rows) await row.evaluate(el => el.scrollBy({left: 70, behavior: "instant"}))
    await expectRowsAtRest(page, width)
    for (const row of rows) await row.evaluate(el => el.scrollTo({left: el.scrollWidth, behavior: "instant"}))
    await expectRowsAtRest(page, width)

    // The last room, reached from the keyboard, stands whole at once.
    for (const row of rows) await row.evaluate(el => el.scrollTo({left: 0, behavior: "instant"}))
    await page.locator("#fleet-channels a").nth(-2).focus()
    await page.keyboard.press("Tab")
    await expect(page.locator("#fleet-channels a").last()).toBeFocused()
    await expectRowsAtRest(page, width)
    expect((await rowsAtRest(page)).flat().filter(item => item.focused).map(item => item.whole)).toEqual([true])

    // The last room, picked, and the last tab, opened, stand whole.
    for (const row of rows) await row.evaluate(el => el.scrollTo({left: 0, behavior: "instant"}))
    await page.locator("#fleet-channels a").last().click()
    await expect(page.locator("#fleet-channels a").last()).toHaveAttribute("aria-current", "page")
    await expectRowsAtRest(page, width)
    expect(await chosenWhole(page)).toEqual([true, true])
    await page.goto(`/cascade/1/proposals`)
    await expect(page.locator("#fleet-tab-proposals")).toHaveAttribute("aria-current", "page")
    await expectRowsAtRest(page, width)
    expect(await chosenWhole(page)).toEqual([true])
  })
}

// On a 320 px phone, signed out, the header keeps its theme switch beside "Buy
// Key": the page's one switch, a whole press wide and tall, in one header row
// whose controls, the crown included, stand whole on screen side by side, and a
// press turns the theme. Nothing scrolls sideways.
for (const path of ["/classic/1", "/account"]) {
  test(`at 320 wide, signed out, ${path} keeps the theme switch beside Buy Key`, async ({page}) => {
    await page.setViewportSize({width: 320, height: 700})
    await page.goto(path)
    await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
    await expect(page.locator("#shell-get-key")).toBeVisible()
    await expect(page.getByRole("switch", {name: "Light theme", includeHidden: true})).toHaveCount(1)
    const toggle = page.locator("#shell-header").getByRole("switch", {name: "Light theme"})
    await expect(toggle).toBeVisible()
    const press = (await toggle.boundingBox())!
    expect(Math.min(press.width, press.height)).toBeGreaterThanOrEqual(40)

    const header = await page.locator("#shell-header").evaluate(el => {
      const box = el.getBoundingClientRect()
      const controls = [el.querySelector(".shell-brand__mark")!, ...el.querySelectorAll(":scope > :not(.shell-brand)")]
        .map(control => control.getBoundingClientRect())
        .filter(control => control.width > 0)
      return {
        height: box.height,
        sideways: el.scrollWidth - el.clientWidth,
        whole: controls.every(control => control.left >= 0 && control.right <= 320 && control.top >= box.top && control.bottom <= box.bottom),
        apart: controls.every((control, i) => i === 0 || control.left >= controls[i - 1].right - 0.5),
      }
    })
    expect(header).toEqual({height: 57, sideways: 0, whole: true, apart: true})
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(320)

    await expect(page.locator("html")).toHaveAttribute("data-theme", "light")
    await toggle.click()
    await expect(page.locator("html")).toHaveAttribute("data-theme", "dark")
    await expect(toggle).toHaveAttribute("aria-checked", "false")
  })
}

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
