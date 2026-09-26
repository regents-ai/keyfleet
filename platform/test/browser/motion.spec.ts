import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {anythingMoved, forget, leftovers, moved, rolled, watchMotion} from "./support/motion"

// Keyfleet's motion plays only for pointer presses and for readers who haven't
// asked for less motion, and every piece hands its element back to the
// stylesheet when it ends. fleet_motion.spec.ts covers the fleet pages.

async function openHomepage(page: Page) {
  await watchMotion(page)
  await page.setViewportSize({width: 1280, height: 720})
  await page.goto("/")
  await expect(page.locator(".phx-connected").first()).toBeAttached()
  await forget(page)
}

async function openAccountMenu(page: Page) {
  const auth = await installAuthenticatedPrivy(page, "valid")
  await auth.establishLocalSession()
  await watchMotion(page)
  await page.goto("/account")
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
  await auth.expectAuthenticatedSession()
  await forget(page)
  return page.locator("#account-menu")
}

test("the homepage's fleet cards settle in once, when first scrolled to, and end clean", async ({page}) => {
  await openHomepage(page)

  await page.locator("#home-fleet-cards").scrollIntoViewIfNeeded()
  await expect.poll(() => moved(page, "#home-fleet-cards > li")).toBe(true)
  await expect.poll(() => leftovers(page)).toEqual([])

  await page.evaluate(() => scrollTo(0, 0))
  await page.waitForTimeout(300)
  await forget(page)
  await page.locator("#home-fleet-cards").scrollIntoViewIfNeeded()
  await page.waitForTimeout(600)
  expect(await moved(page, "#home-fleet-cards > li")).toBe(false)
})

test("a page's headline rises in and is left exactly as the server drew it", async ({page, request}) => {
  const served = await (await request.get("/about")).text()
  await watchMotion(page)
  await page.goto("/about")

  await expect.poll(() => rolled(page, "headline")).toBe(true)
  await expect
    .poll(() =>
      page.evaluate(
        html =>
          new DOMParser().parseFromString(html, "text/html").querySelector("main h1")!.innerHTML ===
          document.querySelector("main h1")!.innerHTML,
        served,
      ),
    )
    .toBe(true)
})

test("a pointer press squishes the account button and pops its menu, and both end clean", async ({page}) => {
  const account = await openAccountMenu(page)

  await account.locator("summary").click()
  await expect(account.locator(".account-menu__content")).toBeVisible()

  await expect.poll(() => moved(page, "#account-menu summary")).toBe(true)
  await expect.poll(() => moved(page, "#account-menu .account-menu__content")).toBe(true)
  await expect.poll(() => leftovers(page)).toEqual([])
})

test("a keyboard press opens the account menu at once, with no squish or pop", async ({page}) => {
  const account = await openAccountMenu(page)

  await account.locator("summary").focus()
  await page.keyboard.press("Enter")
  await expect(account.locator(".account-menu__content")).toBeVisible()
  await page.waitForTimeout(600)

  expect(await anythingMoved(page)).toBe(false)
})

test("a reader who asked for less motion sees presses, menus and cards without movement", async ({browser}) => {
  const context = await browser.newContext({reducedMotion: "reduce"})
  const page = await context.newPage()

  const account = await openAccountMenu(page)
  await account.locator("summary").click()
  await expect(account.locator(".account-menu__content")).toBeVisible()
  await page.waitForTimeout(600)
  expect(await anythingMoved(page), "the account menu").toBe(false)

  await page.goto("/")
  await expect(page.locator(".phx-connected").first()).toBeAttached()
  await page.locator("#home-fleet-cards").scrollIntoViewIfNeeded()
  await page.waitForTimeout(600)
  expect(await anythingMoved(page), "the homepage").toBe(false)

  await page.goto("/about")
  await page.waitForTimeout(600)
  expect(await anythingMoved(page), "a page's headline").toBe(false)
  await context.close()
})
