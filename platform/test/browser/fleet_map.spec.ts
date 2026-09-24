import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {fillLevel, moveKey, pairKey, prepareFleet, sellKey} from "./support/fleet_chain"

// A fleet page's map follows the chain while it is open: keys sold, keys
// changing hands and agents taking keys on reach it without a reload, and a
// page that lost its connection catches up when it comes back. Every run
// starts from the same unsold fleets.
const fleet = "fleet_tech_accelerant"
const me = "0x1111111111111111111111111111111111111111"
const someoneElse = "0x2222222222222222222222222222222222222222"

type Socket = {liveSocket: {connect(): void; disconnect(): void}}

// Opens a fleet page signed in as `me` and waits for the map's first load.
async function openFleet(page: Page, id = fleet) {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  const auth = await installAuthenticatedPrivy(page, "valid")
  await auth.establishLocalSession()
  await page.goto(`/app/fleets/${id}`)
  const stage = page.locator(`#key-map-${id}.key-map--ready`)
  await expect(stage.locator(".km-tile").first()).toBeAttached()
  await stage.scrollIntoViewIfNeeded()
  // Gone after a reload, so its survival shows the page never reloaded.
  await page.evaluate(() => Object.assign(window, {openedOnce: true}))
  return errors
}

const stillOpen = (page: Page) => page.evaluate(() => "openedOnce" in window)

// The marks on every copy of `key` the map draws.
const marksOf = (page: Page, key: number) =>
  page
    .locator(`.km-tile[data-key="${key}"]:not([hidden])`)
    .evaluateAll(tiles => tiles.map(tile => (tile as HTMLElement).dataset.state?.split(" ") ?? []))

// Waits until the map draws `key` and every copy carries `has` and none of `lacks`.
async function expectMarks(page: Page, key: number, has: string[], lacks: string[] = []) {
  await expect
    .poll(async () => {
      const copies = await marksOf(page, key)
      return (
        copies.length > 0 &&
        copies.every(marks => has.every(mark => marks.includes(mark)) && !lacks.some(mark => marks.includes(mark)))
      )
    }, {message: `key ${key} marked ${has.join(" ")} and not ${lacks.join(" ")}`})
    .toBe(true)
}

// How every copy of `key` the map draws says its level stands.
const levelOfKey = (page: Page, key: number) =>
  page
    .locator(`.km-tile[data-key="${key}"]:not([hidden])`)
    .evaluateAll(tiles => [...new Set(tiles.map(tile => (tile as HTMLElement).dataset.level))])

// The level outline drawn round every copy of `key` the map draws, as its
// level and line width.
const outlinesAt = (page: Page, key: number) =>
  page
    .locator(`.km-tile[data-key="${key}"]:not([hidden]) .km-edge[d]`)
    .evaluateAll(paths => [
      ...new Set(paths.map(path => `${(path as SVGPathElement).dataset.level} ${getComputedStyle(path).strokeWidth}`)),
    ])

// The level headings the map draws, and how each says its level stands.
const headings = (page: Page) =>
  page
    .locator(".km-level:not([hidden])")
    .evaluateAll(chips => [...new Set(chips.map(chip => `${chip.textContent} (${(chip as HTMLElement).dataset.level})`))])

// Where the copy of `key` nearest the middle of the map sits on screen.
const tileAt = (page: Page, key: number) =>
  page.evaluate(key => {
    const stage = document.querySelector(".key-map")!.getBoundingClientRect()
    const middle = {x: stage.left + stage.width / 2, y: stage.top + stage.height / 2}
    const [nearest] = [...document.querySelectorAll<HTMLElement>(`.km-tile[data-key="${key}"]:not([hidden])`)]
      .map(tile => {
        const rect = tile.getBoundingClientRect()
        return {x: rect.left + rect.width / 2, y: rect.top + rect.height / 2}
      })
      .filter(({x, y}) => x > stage.left + 50 && x < stage.right - 50 && y > stage.top + 50 && y < stage.bottom - 50)
      .sort((a, b) => Math.hypot(a.x - middle.x, a.y - middle.y) - Math.hypot(b.x - middle.x, b.y - middle.y))
    return nearest
  }, key)

test.describe("the fleet page's map", () => {
  test.beforeAll(() => {
    prepareFleet(fleet)
  })

  test("a key sold appears as yours and the next key moves on, without a reload", async ({page}) => {
    const onSale = prepareFleet(fleet) + 1
    const errors = await openFleet(page)
    await expectMarks(page, onSale, ["next"], ["mine"])

    expect(sellKey(fleet, me)).toBe(onSale)
    await expectMarks(page, onSale, ["mine"], ["next"])
    await expectMarks(page, onSale + 1, ["next"])
    expect(await stillOpen(page)).toBe(true)
    expect(errors).toEqual([])
  })

  test("a key that changes hands stops being yours, and comes back", async ({page}) => {
    const key = sellKey(fleet, me)
    const errors = await openFleet(page)
    await expectMarks(page, key, ["mine"])

    moveKey(fleet, key, someoneElse)
    await expectMarks(page, key, [], ["mine"])
    moveKey(fleet, key, me)
    await expectMarks(page, key, ["mine"])
    expect(await stillOpen(page)).toBe(true)
    expect(errors).toEqual([])
  })

  test("an agent taking a key on marks it", async ({page}) => {
    const key = sellKey(fleet, me)
    const errors = await openFleet(page)
    await expectMarks(page, key, ["mine"], ["agent"])

    pairKey(fleet, key)
    await expectMarks(page, key, ["mine", "agent"])
    expect(await stillOpen(page)).toBe(true)
    expect(errors).toEqual([])
  })

  test("a page that lost its connection catches up when it comes back, cursor and all", async ({page}) => {
    const onSale = prepareFleet(fleet) + 1
    const errors = await openFleet(page)
    await expectMarks(page, onSale, ["next"])
    // Home puts the keyboard cursor on the key on sale.
    await page.locator(`#key-map-${fleet}`).focus()
    await page.keyboard.press("Home")
    await expectMarks(page, onSale, ["next", "cursor"])

    await page.evaluate(() => (window as unknown as Socket).liveSocket.disconnect())
    expect(sellKey(fleet, me)).toBe(onSale)
    // Nothing reaches a page without its connection.
    await page.waitForTimeout(500)
    await expectMarks(page, onSale, ["next"], ["mine"])

    await page.evaluate(() => (window as unknown as Socket).liveSocket.connect())
    await expectMarks(page, onSale, ["mine", "cursor"], ["next"])
    await expectMarks(page, onSale + 1, ["next"])
    expect(await stillOpen(page)).toBe(true)
    expect(errors).toEqual([])
  })

  test("a key chosen on the map opens its profile, which Back closes and Forward opens again", async ({page}) => {
    const key = sellKey(fleet, me)
    const errors = await openFleet(page)
    const chosen = page.locator("#key-map-selected")
    await expect(chosen).toHaveText("No key chosen yet.")

    const at = await tileAt(page, key)
    expect(at, `key ${key} is on screen`).toBeDefined()
    await page.mouse.click(at.x, at.y)
    await expect(page).toHaveURL(new RegExp(`\\?key=${key}$`))
    await expect(page.locator("#key-profile-title")).toHaveText(`Key ${key.toLocaleString("en-US")}`)
    await expect(chosen).toHaveText(`Key ${key.toLocaleString("en-US")} chosen.`)
    await expectMarks(page, key, ["selected"])

    await page.goBack()
    await expect(page).toHaveURL(new RegExp(`/app/fleets/${fleet}$`))
    await expect(page.locator("#key-profile")).toHaveCount(0)
    await expect(chosen).toHaveText("No key chosen yet.")
    await expectMarks(page, key, [], ["selected"])

    await page.goForward()
    await expect(page).toHaveURL(new RegExp(`\\?key=${key}$`))
    await expect(page.locator("#key-profile-title")).toBeFocused()
    await expectMarks(page, key, ["selected"])

    // Closing hands focus back to the map.
    await page.keyboard.press("Escape")
    await expect(page.locator("#key-profile")).toHaveCount(0)
    await expect(page.locator(`#key-map-${fleet}`)).toBeFocused()
    expect(await stillOpen(page)).toBe(true)
    expect(errors).toEqual([])
  })

  // Level 1 of this fleet is keys 1 and 2 and level 2 is keys 3 to 5, each
  // one row: the last key of a level ends its row and the first of the next
  // starts the next row, so both lie on their levels' edges.
  test("when a level sells out, the next level goes on sale, without a reload", async ({page}) => {
    const levelled = "fibonacci_syndicate"
    prepareFleet(levelled)
    const [level, last] = fillLevel(levelled, someoneElse)
    expect([level, last]).toEqual([1, 2])
    const errors = await openFleet(page, levelled)
    await expectMarks(page, last, ["next"])
    await expect.poll(() => levelOfKey(page, last)).toEqual(["on-sale"])
    await expect.poll(() => outlinesAt(page, last)).toEqual(["on-sale 3px"])
    await expect.poll(() => levelOfKey(page, last + 1)).toEqual(["upcoming"])
    await expect.poll(() => outlinesAt(page, last + 1)).toEqual(["upcoming 1.5px"])
    await expect.poll(() => headings(page)).toContain(`Level ${level + 1} (upcoming)`)

    expect(sellKey(levelled, someoneElse)).toBe(last)
    await expectMarks(page, last + 1, ["next"])
    await expect.poll(() => levelOfKey(page, last + 1)).toEqual(["on-sale"])
    await expect.poll(() => outlinesAt(page, last + 1)).toEqual(["on-sale 3px"])
    await expect.poll(() => headings(page)).toContain(`Level ${level + 1} · on sale now (on-sale)`)
    await expect.poll(() => levelOfKey(page, last)).toEqual(["sold-out"])
    await expect.poll(() => outlinesAt(page, last)).toEqual(["sold-out 1px"])
    // Go to level offers the level after the one on sale, which the map draws.
    await page.locator("#key-map-level-choice").selectOption(String(level + 2))
    await page.locator("#key-map-level button[type=submit]").click()
    await expect.poll(() => headings(page)).toContain(`Level ${level + 2} (upcoming)`)
    await page.locator("#key-map-level-choice").selectOption(String(level))
    await page.locator("#key-map-level button[type=submit]").click()
    await expect.poll(() => headings(page)).toContain(`Level ${level} · sold out (sold-out)`)
    expect(await stillOpen(page)).toBe(true)
    expect(errors).toEqual([])
  })
})
