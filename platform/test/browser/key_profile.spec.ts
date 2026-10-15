import {expect, test, type Browser, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {offerRewards, prepareFleet, sellKey} from "./support/fleet_chain"

// A key's profile opens over its fleet's page: from the member list, from the
// map, or straight from an address naming the key. Every run starts from the
// same unsold fleets.
const fleet = "fibonacci_cascade"
const me = "0x1111111111111111111111111111111111111111"
const otherAccount = "0x3333333333333333333333333333333333333333"
const fleetPath = `/cascade/1`

// Opens a page signed in with `bearer`; returns the page's uncaught errors.
async function signIn(page: Page, bearer = "valid") {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  const auth = await installAuthenticatedPrivy(page, bearer)
  await auth.establishLocalSession()
  return errors
}

async function openFleet(page: Page, query = "") {
  await page.goto(fleetPath + query)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
}

const profile = (page: Page) => page.locator("dialog#key-profile")
const focusInside = (page: Page) =>
  page.evaluate(() => document.querySelector("#key-profile")?.contains(document.activeElement) ?? false)
const withoutKey = new RegExp(`${fleetPath}(\\?view=members)?$`)

test.describe("a key's profile", () => {
  test.beforeAll(() => {
    prepareFleet(fleet)
  })

  test("opens from the list with its title focused, keeps Tab inside, and Escape hands focus back", async ({page}) => {
    const key = sellKey(fleet, me)
    const errors = await signIn(page)
    await openFleet(page, "?view=members")

    const link = page.locator(`#fleet-members-card-${key}`)
    await link.click()
    await expect(page).toHaveURL(new RegExp(`[?&]key=${key}$`))
    await expect(profile(page)).toBeVisible()
    await expect(page.locator("#key-profile-title")).toHaveText(`Key ${key}`)
    await expect(page.locator("#key-profile-title")).toBeFocused()

    for (const shift of [false, true]) {
      for (let press = 0; press < 25; press++) {
        await page.keyboard.press(shift ? "Shift+Tab" : "Tab")
        expect(await focusInside(page), `focus after ${press + 1} ${shift ? "Shift+Tab" : "Tab"}`).toBe(true)
      }
    }

    await page.keyboard.press("Escape")
    await expect(profile(page)).toHaveCount(0)
    await expect(page).toHaveURL(withoutKey)
    await expect(page.locator(`#fleet-members-card-${key}`)).toBeFocused()
    expect(errors).toEqual([])
  })

  test("Back closes it and Forward opens it again", async ({page}) => {
    const key = sellKey(fleet, me)
    const errors = await signIn(page)
    await openFleet(page, "?view=members")

    await page.locator(`#fleet-members-card-${key}`).click()
    await expect(profile(page)).toBeVisible()

    await page.goBack()
    await expect(profile(page)).toHaveCount(0)
    await expect(page).toHaveURL(withoutKey)

    await page.goForward()
    await expect(page).toHaveURL(new RegExp(`[?&]key=${key}$`))
    await expect(profile(page)).toBeVisible()
    await expect(page.locator("#key-profile-title")).toBeFocused()
    expect(errors).toEqual([])
  })

  test("arriving with a key in the address and closing it adds no step to go back through", async ({page}) => {
    const key = sellKey(fleet, me)
    const errors = await signIn(page)
    await openFleet(page, `?key=${key}`)
    await expect(profile(page)).toBeVisible()
    const steps = await page.evaluate(() => history.length)

    await page.locator("#key-profile-close").click()
    await expect(profile(page)).toHaveCount(0)
    await expect(page).toHaveURL(withoutKey)
    expect(await page.evaluate(() => history.length)).toBe(steps)
    expect(errors).toEqual([])
  })

  test("a message someone else writes to the key appears without a reload", async ({browser, page}) => {
    const key = sellKey(fleet, me)
    sellKey(fleet, otherAccount)
    const errors = await signIn(page)
    await openFleet(page, `?key=${key}`)
    await page.evaluate(() => Object.assign(window, {openedOnce: true}))

    const writer = await otherVisitor(browser)
    await writer.locator("#key-profile-composer-body").fill("Hull survey started")
    await writer.locator("#key-profile-composer button[type=submit]").click()
    await expect(writer.locator("#key-profile-thread")).toContainText("Hull survey started")

    await expect(page.locator("#key-profile-thread")).toContainText("Hull survey started")
    await expect(page.locator("#key-profile-news")).toHaveText(`New message to Key ${key}.`)
    expect(await page.evaluate(() => "openedOnce" in window)).toBe(true)
    expect(errors).toEqual([])

    async function otherVisitor(browser: Browser) {
      const context = await browser.newContext()
      const other = await context.newPage()
      await signIn(other, "other-account")
      await openFleet(other, `?key=${key}`)
      return other
    }
  })

  test("shows the rewards waiting for the key once they are read", async ({page}) => {
    const key = sellKey(fleet, me)
    offerRewards(fleet, key, 2_500_000)
    const errors = await signIn(page)
    await openFleet(page, `?key=${key}`)

    await expect(page.locator("#key-profile-rewards")).toHaveText("2.5 USDC")
    expect(errors).toEqual([])
  })

  test("says so when the rewards can't be read, and the rest of it still works", async ({page}) => {
    const key = sellKey(fleet, me)
    const errors = await signIn(page)
    await openFleet(page, `?key=${key}`)

    await expect(page.locator("#key-profile-rewards")).toHaveText("Couldn’t read rewards right now.")
    await page.locator("#key-profile-composer-body").fill("Rewards later")
    await page.locator("#key-profile-composer button[type=submit]").click()
    await expect(page.locator("#key-profile-thread")).toContainText("Rewards later")

    await page.locator("#key-profile-close").click()
    await expect(profile(page)).toHaveCount(0)
    expect(errors).toEqual([])
  })

  test.describe("on a phone", () => {
    test.use({viewport: {width: 375, height: 812}})

    test("sits as a sheet over the fleet's page, never scrolls sideways, and the box to write in is reached by keyboard", async ({
      page,
    }) => {
      const key = sellKey(fleet, me)
      const errors = await signIn(page)
      await openFleet(page, `?key=${key}`)
      await expect(profile(page)).toBeVisible()

      const box = await profile(page).boundingBox()
      // Against the bottom edge, with a strip of the fleet's page showing above.
      expect(box).toEqual({x: 0, y: 48, width: 375, height: 764})
      const sideways = await profile(page).evaluate(dialog => dialog.scrollWidth - dialog.clientWidth)
      expect(sideways).toBeLessThanOrEqual(0)

      const composer = page.locator("#key-profile-composer-body")
      for (let press = 0; press < 60 && !(await composer.evaluate(box => box === document.activeElement)); press++) {
        await page.keyboard.press("Tab")
      }
      await expect(composer).toBeFocused()
      await expect(composer).toBeInViewport()
      expect(errors).toEqual([])
    })
  })
})
