import {randomBytes} from "node:crypto"
import {expect, test, type Locator, type Page} from "@playwright/test"
import {prepareFleet, writeHistory} from "./support/fleet_chain"

// A fleet's Worldline, read signed out: the picture draws a fortnight of the
// fleet's history in three dimensions. A drag turns it and opens nothing,
// Reset and a double-click turn it back, a scroll or a drag with Shift moves
// it through time, Now brings it back, the zoom buttons and a pinch zoom it,
// the keyboard does all of it, the mark pointed at links to the page it
// happened on, in a new tab too, and the filter shows one Key's events or
// one wallet's. The first walks ask for less motion, so the picture holds
// still and a mark stays where it was found; the last ones watch it move.
// Each worker's owner is a new wallet, so it holds the one Key its history
// is written as.
const fleet = "fleet_tech_classic"
const owner = `0x7d${randomBytes(19).toString("hex")}`
// A wallet with nothing in the fleet.
const stranger = "0x0000000000000000000000000000000000000001"

// The headless shell Playwright runs by default hands out no WebGPU canvas
// textures, so the picture never draws there; full Chromium draws it.
test.use({channel: "chromium"})

let key = 0

test.beforeAll(() => {
  prepareFleet(fleet)
  key = writeHistory(fleet, owner)
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

// Presses at `from` and drags `dx` across in a few steps, then lets go.
async function drag(page: Page, from: {x: number; y: number}, dx: number) {
  await page.mouse.move(from.x, from.y)
  await page.mouse.down()
  for (let step = 1; step <= 4; step++) await page.mouse.move(from.x + (step * dx) / 4, from.y)
  await page.mouse.up()
}

// Errors on the page, and any the GPU reports to the console.
function watchErrors(page: Page) {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  page.on("console", message => {
    if (message.type() === "error" && /gpu|wgsl/i.test(message.text())) errors.push(message.text())
  })
  return errors
}

// Opens a Worldline page; the picture is drawn once it is in view.
async function open(page: Page, url: string) {
  await page.goto(url)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  const stage = page.locator("#worldline-stage")
  await stage.scrollIntoViewIfNeeded()
  await expect(stage).toHaveAttribute("data-worldline-ready", "true", {timeout: 15_000})
}

// Where the sun stands in the picture: its word for what just arrived is
// kept over it, wherever the camera turns.
const sun = (page: Page) =>
  page.locator("[data-worldline-news]").evaluate(element => {
    const shift = new DOMMatrix(getComputedStyle(element).transform)
    return {x: shift.m41, y: shift.m42}
  })

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
const apart = (a: {x: number; y: number}, b: {x: number; y: number}) => Math.hypot(a.x - b.x, a.y - b.y)

for (const width of [390, 1280]) {
  test(`a signed-out reader turns, moves and zooms the Worldline and opens its events at ${width} wide`, async ({page}, info) => {
    const errors = watchErrors(page)
    await page.emulateMedia({reducedMotion: "reduce"})
    await page.setViewportSize({width, height: 900})
    await open(page, "/classic/1/worldline")

    const stage = page.locator("#worldline-stage")
    const link = page.locator("[data-worldline-focus]")
    const now = page.locator("[data-worldline-now]")
    const level = page.locator("[data-worldline-zoom-level]")
    const legend = page.locator("#worldline-legend")
    for (const name of ["Workspace", "Code", "Notebooks", "Chat"]) await expect(legend).toContainText(name)
    expect(await sideways(page)).toBeLessThanOrEqual(width)
    await expect(level).toHaveText("100%")
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
    expect(href).toMatch(/^\/classic\/1[/?]/)
    const before = (await link.boundingBox())!
    const home = await sun(page)

    // A drag begun on the mark turns the picture, the mark's link turning with
    // it, and opens nothing.
    await drag(page, found, 60)
    expect(apart((await link.boundingBox())!, before)).toBeGreaterThan(4)
    expect(apart(await sun(page), home)).toBeGreaterThan(4)
    expect(await link.innerText()).toBe(card)
    expect(path(page.url())).toBe("/classic/1/worldline")

    // Reset turns it back, the mark and all.
    await page.locator("[data-worldline-reset]").click()
    await expect.poll(async () => apart(await sun(page), home)).toBeLessThan(0.5)
    expect(apart((await link.boundingBox())!, before)).toBeLessThan(0.5)

    // So does a double-click on the picture.
    await drag(page, found, 60)
    expect(apart(await sun(page), home)).toBeGreaterThan(4)
    const empty = (await stage.boundingBox())!
    await page.mouse.dblclick(empty.x + empty.width / 2, empty.y + 6)
    await expect.poll(async () => apart(await sun(page), home)).toBeLessThan(0.5)

    // Scrolling over the picture moves it back through time, carrying the mark
    // with the line, and leaves the page where it was; Now brings it back.
    await page.mouse.move(found.x, found.y)
    await expect(link).toBeVisible()
    const shown = await link.innerText()
    const at = (await link.boundingBox())!
    const pageTop = await scrolled(page)
    await page.mouse.wheel(0, -100)
    await expect(now).toBeVisible()
    await expect.poll(async () => (await link.boundingBox())!.x - at.x).toBeGreaterThan(40)
    expect((await link.boundingBox())!.x - at.x).toBeLessThan(160)
    expect(await scrolled(page)).toBe(pageTop)
    expect(await link.innerText()).toBe(shown)
    await now.click()
    await expect(now).toBeHidden()
    await expect.poll(async () => apart((await link.boundingBox())!, at)).toBeLessThan(0.5)

    // A drag with Shift held moves through time too, and opens nothing.
    await page.mouse.move(found.x, found.y)
    const pressed = (await link.boundingBox())!
    const held = await link.innerText()
    await page.keyboard.down("Shift")
    await drag(page, found, 80)
    await page.keyboard.up("Shift")
    await expect(now).toBeVisible()
    await expect.poll(async () => (await link.boundingBox())!.x - pressed.x).toBeGreaterThan(30)
    expect((await link.boundingBox())!.x - pressed.x).toBeLessThan(130)
    expect(await link.innerText()).toBe(held)
    expect(path(page.url())).toBe("/classic/1/worldline")
    await now.click()
    await expect(now).toBeHidden()

    // The zoom buttons zoom in and out, and say how far.
    await page.getByRole("button", {name: "Zoom in"}).click()
    await expect(level).toHaveText("143%")
    await page.getByRole("button", {name: "Zoom out"}).click()
    await expect(level).toHaveText("100%")

    // Ctrl and the wheel, as a pinch on a trackpad, zoom toward the pointer.
    await page.mouse.move(found.x, found.y)
    await page.keyboard.down("Control")
    await page.mouse.wheel(0, -100)
    await page.keyboard.up("Control")
    await expect(level).toHaveText("165%")
    expect(await scrolled(page)).toBe(pageTop)

    // The keyboard reaches a mark, moves, zooms, turns and comes back to now.
    await stage.focus()
    await page.keyboard.press("End")
    await page.keyboard.press("ArrowLeft")
    await expect(link).toBeVisible()
    await expect(now).toBeVisible()
    await page.keyboard.press("-")
    await expect(level).toHaveText("115%")
    const keyed = (await link.boundingBox())!
    await page.keyboard.press("Alt+ArrowLeft")
    await expect.poll(async () => apart((await link.boundingBox())!, keyed)).toBeGreaterThan(1)
    await page.keyboard.press("End")
    await expect(now).toBeHidden()
    // Escape lets the mark go, so the pointer shows marks again.
    await page.keyboard.press("Escape")
    await expect(link).toBeHidden()

    // A mark's link opens the page it happened on, in a new tab and in this one.
    await page.mouse.move(1, 1)
    await page.locator("[data-worldline-reset]").click()
    const again = await pointAtMark(page, stage, link)
    const opens = (await link.getAttribute("href"))!
    const [tab] = await Promise.all([page.context().waitForEvent("page"), link.click({modifiers: ["ControlOrMeta"]})])
    await tab.waitForLoadState()
    expect(path(tab.url())).toBe(opens)
    await tab.close()

    await page.mouse.move(again.x, again.y)
    await link.click()
    await expect.poll(() => path(page.url())).toBe(opens)
    await page.goBack()
    await expect(stage).toHaveAttribute("data-worldline-ready", "true")

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
    const errors = watchErrors(page)
    await page.emulateMedia({reducedMotion: "reduce"})
    // A short window gives the page room to scroll.
    await page.setViewportSize({width, height: 520})
    await open(page, "/classic/1/worldline")

    const stage = page.locator("#worldline-stage")
    const now = page.locator("[data-worldline-now]")
    const scroller = page.locator("#app-shell-scroller")
    await scroller.evaluate(element => element.scrollTo(0, 0))

    // Off the picture the wheel scrolls the page.
    const legend = (await page.locator("#worldline-legend").boundingBox())!
    await page.mouse.move(legend.x + 4, legend.y + legend.height / 2)
    await page.mouse.wheel(0, 120)
    await expect.poll(() => scrolled(page)).toBeGreaterThan(0)

    // On it, at now, scrolling on toward now scrolls the page too, and the
    // picture stays at the head. The picture's top is brought near the
    // window's first, with the page still able to scroll on.
    await page.waitForTimeout(600)
    const below = (await stage.boundingBox())!.y - 100
    await scroller.evaluate((element, by) => element.scrollBy(0, by), below)
    await page.waitForTimeout(600)
    const top = await scrolled(page)
    const over = (await stage.boundingBox())!
    expect(over.y).toBeLessThan(160)
    await page.mouse.move(over.x + over.width / 2, over.y + 60)
    await page.mouse.wheel(0, 120)
    await expect.poll(() => scrolled(page)).toBeGreaterThan(top)
    await expect(now).toBeHidden()
    expect(errors).toEqual([])
  })

  test(`the Worldline moves on its own and still opens the mark pointed at, at ${width} wide`, async ({page}) => {
    const errors = watchErrors(page)
    await page.setViewportSize({width, height: 900})
    await open(page, "/classic/1/worldline")

    const stage = page.locator("#worldline-stage")
    const link = page.locator("[data-worldline-focus]")

    // The marks keep shimmering.
    await page.waitForTimeout(1600)
    const first = await drawn(page, stage)
    await page.waitForTimeout(1000)
    expect((await drawn(page, stage)).equals(first)).toBe(false)

    // Pointed at, a mark's link holds still on it, and opens the page it
    // happened on.
    await pointAtMark(page, stage, link)
    const href = (await link.getAttribute("href"))!
    expect(href).toMatch(/^\/classic\/1[/?]/)
    await page.waitForTimeout(700)
    const held = (await link.boundingBox())!
    await page.waitForTimeout(500)
    expect(apart((await link.boundingBox())!, held)).toBeLessThan(1)
    expect(await link.getAttribute("href")).toBe(href)
    await link.click()
    await expect.poll(() => path(page.url())).toBe(href)
    expect(errors).toEqual([])
  })
}

test("the filter shows one Key's events or one wallet's, and says when it can't read the words", async ({page}) => {
  const errors = watchErrors(page)
  await page.emulateMedia({reducedMotion: "reduce"})
  await page.setViewportSize({width: 1280, height: 900})
  await open(page, "/classic/1/worldline")

  const field = page.getByLabel("Filter")
  await expect(field).toHaveAttribute("placeholder", "Key 19 or 0x…")

  // By the Key's number: the address keeps it, and the list holds only its events.
  await field.fill(`Key ${key}`)
  await page.locator("#worldline-filter-apply").click()
  await expect.poll(() => path(page.url())).toBe(`/classic/1/worldline?by=${key}`)
  await expect(page.locator("#worldline-stage")).toHaveAttribute("data-worldline-ready", "true")
  await expect(field).toHaveValue(`Key ${key}`)
  await page.locator("#worldline-show-list").click()
  await expect.poll(() => path(page.url())).toBe(`/classic/1/worldline?show=list&by=${key}`)
  const who = page.locator("#worldline-events .worldline-event__who")
  await expect(who.first()).toBeVisible()
  for (const each of await who.allInnerTexts()) expect(each).toBe(`Key ${key}`)

  // By the wallet that holds it: the same events.
  await field.fill(owner.toUpperCase().replace("0X", "0x"))
  await page.locator("#worldline-filter-apply").click()
  await expect.poll(() => path(page.url())).toBe(`/classic/1/worldline?show=list&by=${owner}`)
  await expect(who.first()).toBeVisible()
  for (const each of await who.allInnerTexts()) expect(each).toBe(`Key ${key}`)

  // Words that name no Key or wallet are answered beside the field.
  await field.fill("someone")
  await page.locator("#worldline-filter-apply").click()
  await expect(page.locator("#worldline-filter")).toContainText("Enter a Key number or a 0x address.")
  await expect(field).toHaveAttribute("aria-invalid", "true")

  // Clear shows everyone's again.
  await page.locator("#worldline-filter-clear").click()
  await expect.poll(() => path(page.url())).toBe("/classic/1/worldline?show=list")
  await expect(field).toHaveValue("")
  await expect(page.locator("#worldline-filter-clear")).toHaveCount(0)

  // A wallet with nothing in the fleet: the picture still draws, and says so.
  await open(page, `/classic/1/worldline?by=${stranger}`)
  await expect(page.locator("#worldline-empty")).toContainText("Nothing matches this filter yet.")
  expect(errors).toEqual([])
})

test("the Worldline never scrolls sideways, at any width", async ({page}) => {
  for (const width of [320, 390, 768, 1280]) {
    await page.setViewportSize({width, height: 800})
    await open(page, "/classic/1/worldline")
    expect(await sideways(page)).toBeLessThanOrEqual(width)
    await page.goto("/classic/1/worldline?show=list")
    await expect(page.locator("#worldline-events li").first()).toBeVisible()
    expect(await sideways(page)).toBeLessThanOrEqual(width)
  }
})

// Each theme and width, turned three ways: side on, three-quarters and down
// the line; each view is a different picture, and a resize redraws it at the
// new size. The shots are kept to look at.
for (const [width, theme] of [
  [1280, "dark"],
  [1280, "light"],
  [390, "dark"],
  [390, "light"],
] as const) {
  test(`the Worldline draws in the ${theme} theme at ${width} wide, at every turn`, async ({page, context, baseURL}, info) => {
    const errors = watchErrors(page)
    await context.addCookies([{name: "regent_theme", value: theme, url: baseURL!}])
    await page.setViewportSize({width, height: 900})
    await open(page, "/classic/1/worldline")
    const stage = page.locator("#worldline-stage")
    const shot = (name: string) => stage.screenshot({path: info.outputPath(`worldline-${width}-${theme}-${name}.png`)})

    // Drawn out to the sun, the planets on their orbits.
    await page.waitForTimeout(1800)
    await page.mouse.move(1, 1)
    await page.screenshot({path: info.outputPath(`worldline-${width}-${theme}-page.png`)})
    const home = await shot("three-quarter")

    // Turned from the keyboard, then let go of it, so its middle guide goes.
    const turn = async (presses: string[]) => {
      await stage.focus()
      for (const press of presses) await page.keyboard.press(press)
      await stage.blur()
    }
    await turn([...Array(3).fill("Alt+ArrowRight"), ...Array(2).fill("Alt+ArrowUp")])
    const side = await shot("side-on")
    expect(side.equals(home)).toBe(false)

    await turn(Array(12).fill("Alt+ArrowLeft"))
    const down = await shot("down-axis")
    expect(down.equals(side)).toBe(false)

    await open(page, `/classic/1/worldline?by=${stranger}`)
    await page.waitForTimeout(1200)
    await page.mouse.move(1, 1)
    await shot("none")

    // Resized, the picture is drawn again at its new size.
    const canvas = page.locator("[data-worldline-canvas]")
    const across = () =>
      canvas.evaluate(element => {
        const box = element.getBoundingClientRect()
        return [(element as HTMLCanvasElement).width, Math.floor(box.width * devicePixelRatio)]
      })
    const [wide] = await across()
    await page.setViewportSize({width: Math.round(width * 0.8), height: 760})
    await expect.poll(async () => (await across())[0]).toBeLessThan(wide)
    const [drawnAcross, boxAcross] = await across()
    expect(drawnAcross).toBe(boxAcross)
    await shot("resized")
    expect(errors).toEqual([])
  })
}
