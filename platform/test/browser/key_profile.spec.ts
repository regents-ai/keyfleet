import {expect, test, type Browser, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {prepareFleet, sellKey} from "./support/fleet_chain"

// A key's profile opens over its fleet's page: from the key list, from the
// map, or straight from an address naming the key. Every run starts from the
// same unsold fleets.
const fleet = "fibonacci_cascade"
const me = "0x1111111111111111111111111111111111111111"
const otherAccount = "0x3333333333333333333333333333333333333333"
const fleetPath = `/app/fleets/${fleet}`

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
const withoutKey = new RegExp(`${fleetPath}$`)

test.describe("a key's profile", () => {
  test.beforeAll(() => {
    prepareFleet(fleet)
  })

  test("opens from the list with its title focused, keeps Tab inside, and Escape hands focus back", async ({page}) => {
    const key = sellKey(fleet, me)
    const errors = await signIn(page)
    await openFleet(page)

    const link = page.locator(`#fleet-key-link-${key}`)
    await link.click()
    await expect(page).toHaveURL(new RegExp(`\\?key=${key}$`))
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
    await expect(page.locator(`#fleet-key-link-${key}`)).toBeFocused()
    expect(errors).toEqual([])
  })

  test("Back closes it and Forward opens it again", async ({page}) => {
    const key = sellKey(fleet, me)
    const errors = await signIn(page)
    await openFleet(page)

    await page.locator(`#fleet-key-link-${key}`).click()
    await expect(profile(page)).toBeVisible()

    await page.goBack()
    await expect(profile(page)).toHaveCount(0)
    await expect(page).toHaveURL(withoutKey)

    await page.goForward()
    await expect(page).toHaveURL(new RegExp(`\\?key=${key}$`))
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

  test.describe("its foil card", () => {
    const card = (page: Page) => page.locator("#key-profile-card")
    const liveFoils = (page: Page) => page.locator('[data-holo-ready="true"]').count()
    const drawsFoil = (page: Page) =>
      page.evaluate(async () => Boolean(navigator.gpu && (await navigator.gpu.requestAdapter())))
    const tilt = (page: Page) => card(page).evaluate(element => element.style.getPropertyValue("--rg-holo-tilt-x"))

    // The console's errors as well as the page's uncaught ones.
    async function watch(page: Page) {
      const errors = await signIn(page)
      page.on("console", message => {
        if (message.type() === "error") errors.push(message.text())
      })
      return errors
    }

    async function sweep(page: Page) {
      const box = (await card(page).boundingBox())!
      for (const [x, y] of [[0.2, 0.2], [0.8, 0.3], [0.7, 0.8], [0.3, 0.7]]) {
        await page.mouse.move(box.x + box.width * x, box.y + box.height * y, {steps: 4})
      }
    }

    test("stays within two live foils through five switches and five closes, keeping one canvas", async ({page}) => {
      const keys = Array.from({length: 6}, () => sellKey(fleet, me))
      const errors = await watch(page)
      await openFleet(page)
      const gpu = await drawsFoil(page)

      await page.locator(`#fleet-key-link-${keys[0]}`).hover()
      await page.locator(`#fleet-key-link-${keys[0]}`).click()
      await expect(card(page)).toBeVisible()
      if (gpu) await expect(card(page)).toHaveAttribute("data-holo-ready", "true")
      else await expect(card(page)).not.toHaveAttribute("data-holo-ready")
      await card(page).locator("canvas").evaluate(canvas => Object.assign(canvas, {firstCanvas: true}))

      for (const key of keys.slice(1)) {
        await page.locator(`#key-profile-key-${key}`).click()
        await expect(page.locator("#key-profile-title")).toHaveText(`Key ${key}`)
        await sweep(page)
        expect(await liveFoils(page)).toBeLessThanOrEqual(2)
        expect(await card(page).locator("canvas").evaluate(canvas => "firstCanvas" in canvas)).toBe(true)
      }

      for (const key of keys.slice(0, 5)) {
        await page.keyboard.press("Escape")
        await expect(profile(page)).toHaveCount(0)
        expect(await liveFoils(page)).toBeLessThanOrEqual(1)
        await page.locator(`#fleet-key-link-${key}`).click()
        await expect(card(page)).toBeVisible()
        if (gpu) await expect(card(page)).toHaveAttribute("data-holo-ready", "true")
        expect(await liveFoils(page)).toBeLessThanOrEqual(2)
      }
      expect(errors).toEqual([])
    })

    test("turns and lights under a mouse where the foil draws", async ({page}) => {
      const key = sellKey(fleet, me)
      const errors = await watch(page)
      await openFleet(page, `?key=${key}`)
      test.skip(!(await drawsFoil(page)), "this browser draws no foil, so the card stays still")

      await expect(card(page)).toHaveAttribute("data-holo-ready", "true")
      await sweep(page)
      await expect.poll(() => tilt(page)).toMatch(/^-?\d/)
      expect(await tilt(page)).not.toBe("0rad")
      expect(errors).toEqual([])
    })

    test("without WebGPU shows the still foil and no errors", async ({page}) => {
      await page.addInitScript(() => Object.defineProperty(Navigator.prototype, "gpu", {get: () => undefined}))
      const key = sellKey(fleet, me)
      const errors = await watch(page)
      await openFleet(page, `?key=${key}`)
      await expect(card(page)).toBeVisible()

      await sweep(page)
      await expect(card(page)).not.toHaveAttribute("data-holo-ready")
      const still = await card(page)
        .locator(".rg-holo__stage")
        .evaluate(stage => getComputedStyle(stage, "::before").content)
      expect(still).not.toBe("none")
      expect(await tilt(page)).toBe("")
      expect(errors).toEqual([])
    })

    test("never turns for a visitor who asked for less motion", async ({page}) => {
      await page.emulateMedia({reducedMotion: "reduce"})
      const key = sellKey(fleet, me)
      const errors = await watch(page)
      await openFleet(page, `?key=${key}`)
      await expect(card(page)).toBeVisible()

      await sweep(page)
      await expect(card(page)).not.toHaveAttribute("data-holo-ready")
      expect(await tilt(page)).toBe("")
      expect(await card(page).evaluate(element => getComputedStyle(element).transform)).toBe("none")
      expect(errors).toEqual([])
    })

    test("keeps an outline and stands still in forced colours", async ({page, browserName}) => {
      test.skip(browserName === "webkit", "WebKit cannot be asked for forced colours")
      await page.emulateMedia({forcedColors: "active"})
      const key = sellKey(fleet, me)
      await signIn(page)
      await openFleet(page, `?key=${key}`)
      await sweep(page)

      const look = await card(page).evaluate(element => {
        const stage = element.querySelector(".rg-holo__stage")!
        return {
          forced: matchMedia("(forced-colors: active)").matches,
          transform: getComputedStyle(element).transform,
          edge: getComputedStyle(stage).backgroundColor,
          face: getComputedStyle(stage, "::before").backgroundColor,
        }
      })
      expect(look.forced).toBe(true)
      expect(look.transform).toBe("none")
      expect(look.edge).not.toBe(look.face)
    })
  })

  test.describe("on a touch screen", () => {
    test.skip(({browserName}) => browserName === "firefox", "Firefox cannot pose as a phone")
    test.use({viewport: {width: 375, height: 812}, isMobile: true, hasTouch: true})

    test("the card never turns", async ({page}) => {
      const key = sellKey(fleet, me)
      const errors = await signIn(page)
      await openFleet(page, `?key=${key}`)
      const card = page.locator("#key-profile-card")
      await expect(card).toBeVisible()
      expect(await page.evaluate(() => matchMedia("(pointer: fine)").matches)).toBe(false)

      const box = (await card.boundingBox())!
      await card.tap({position: {x: box.width * 0.8, y: box.height * 0.3}})
      await page.mouse.move(box.x + box.width * 0.2, box.y + box.height * 0.2, {steps: 4})
      const turned = await card.evaluate(element => element.style.getPropertyValue("--rg-holo-tilt-x"))
      expect(["", "0rad"]).toContain(turned)
      expect(errors).toEqual([])
    })
  })

  test.describe("on a phone", () => {
    test.use({viewport: {width: 375, height: 812}})

    test("fills the screen, never scrolls sideways, and the box to write in is reached by keyboard", async ({
      page,
    }) => {
      const key = sellKey(fleet, me)
      const errors = await signIn(page)
      await openFleet(page, `?key=${key}`)
      await expect(profile(page)).toBeVisible()

      const box = await profile(page).boundingBox()
      expect(box).toEqual({x: 0, y: 0, width: 375, height: 812})
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
