import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {anythingMoved, clippedByClass, forget, leftovers, moved, rolled, watchMotion} from "./support/motion"

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

async function openAccount(page: Page) {
  const auth = await installAuthenticatedPrivy(page, "valid")
  await auth.establishLocalSession()
  await watchMotion(page)
  await page.goto("/account")
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
  await auth.expectAuthenticatedSession()
  await forget(page)
}

// The account page hears that a connection couldn't be verified, as it does
// when the provider turns one down, and shows why.
const refuseConnection = (page: Page) =>
  page.evaluate(() => window.dispatchEvent(new CustomEvent("ash:identity-state", {detail: {error: "failed"}})))

const REFUSAL = "#account-verified-connections-notice"

// Serves the page under its own policy with style attributes refused outright,
// and collects whatever the browser refuses.
async function refuseStyleAttributes(page: Page, path: string) {
  await page.route(path, async route => {
    const response = await route.fetch()
    const headers = response.headers()
    const policy = headers["content-security-policy"]
    expect(policy).toMatch(/style-src-attr [^;]+/)
    headers["content-security-policy"] = policy.replace(/style-src-attr [^;]+/, "style-src-attr 'none'")
    await route.fulfill({response, headers})
  })
  const refusals: string[] = []
  page.on("console", message => {
    if (message.text().includes("Refused to")) refusals.push(message.text())
  })
  return refusals
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
  const served = await (await request.get("/docs")).text()
  await watchMotion(page)
  await page.goto("/docs")

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

test("a headline's words rise each in a box clipped by class, so a policy refusing style attributes refuses nothing", async ({
  page,
}) => {
  const refusals = await refuseStyleAttributes(page, "**/docs")
  await watchMotion(page)
  await page.goto("/docs")

  await expect.poll(() => rolled(page, "headline")).toBe(true)
  expect(await clippedByClass(page, "headline")).toBe(true)
  await expect.poll(() => page.locator("main h1 .split-clip").count()).toBe(0)
  await page.waitForLoadState("networkidle")
  expect(refusals).toEqual([])
})

test("a refusal shakes once as it appears, and refusals again and again end at rest", async ({page}) => {
  await openAccount(page)

  await refuseConnection(page)
  await expect(page.locator(REFUSAL)).toHaveText("That connection couldn’t be verified. Try again.")
  await expect(page.locator(REFUSAL)).toHaveAttribute("data-refused")
  await expect.poll(() => moved(page, REFUSAL)).toBe(true)
  await expect.poll(() => leftovers(page)).toEqual([])

  for (let refusal = 0; refusal < 5; refusal++) {
    await refuseConnection(page)
    await page.waitForTimeout(70)
  }
  await expect(page.locator(REFUSAL)).toBeVisible()
  await expect.poll(() => leftovers(page)).toEqual([])
  expect(await page.locator(REFUSAL).getAttribute("style")).toBeNull()
})

test("a reader who asked for less motion sees refusals and cards without movement", async ({browser}) => {
  const context = await browser.newContext({reducedMotion: "reduce"})
  const page = await context.newPage()

  await openAccount(page)
  await refuseConnection(page)
  await expect(page.locator(REFUSAL)).toBeVisible()
  await page.waitForTimeout(600)
  expect(await anythingMoved(page), "a refusal").toBe(false)

  await page.goto("/")
  await expect(page.locator(".phx-connected").first()).toBeAttached()
  await page.locator("#home-fleet-cards").scrollIntoViewIfNeeded()
  await page.waitForTimeout(600)
  expect(await anythingMoved(page), "the homepage").toBe(false)

  await page.goto("/docs")
  await page.waitForTimeout(600)
  expect(await anythingMoved(page), "a page's headline").toBe(false)
  await context.close()
})
