import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {anythingMoved, forget, leftovers, moved, watchMotion} from "./support/motion"

// Keyfleet's motion plays only for pointer presses and for readers who haven't
// asked for less motion, and every piece hands its element back to the
// stylesheet when it ends. fleet_motion.spec.ts covers the fleet pages.

async function openConnections(page: Page) {
  const auth = await installAuthenticatedPrivy(page, "valid")
  await auth.establishLocalSession()
  await watchMotion(page)
  await page.goto("/account/connections")
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
  await auth.expectAuthenticatedSession()
  await forget(page)
}

// The Connections tab hears that a connection couldn't be verified, as it does
// when the provider turns one down, and shows why.
const refuseConnection = (page: Page) =>
  page.evaluate(() => window.dispatchEvent(new CustomEvent("ash:identity-state", {detail: {error: "failed"}})))

const CONNECTIONS = "#account-verified-connections"
const REFUSAL = `${CONNECTIONS}-notice`

test("a refusal shakes once as it appears, and refusals again and again end at rest", async ({page}) => {
  await openConnections(page)

  await refuseConnection(page)
  await expect(page.locator(REFUSAL)).toHaveText("That connection couldn’t be verified. Try again.")
  await expect(page.locator(REFUSAL)).toHaveAttribute("data-refused")
  await expect.poll(() => moved(page, REFUSAL)).toBe(true)
  await expect.poll(() => leftovers(page)).toEqual([])

  for (let refusal = 0; refusal < 5; refusal++) {
    await refuseConnection(page)
    await page.waitForTimeout(70)
  }
  // Each refusal goes to the server, which takes the message away and shows it
  // again once it has read the connections; each new message starts shaking on
  // the next frame. The section is marked `phx-hook-loading` until the server
  // has answered the last refusal, so the message shown after that is the last
  // one, judged once its shake has begun and ended.
  await expect(page.locator(CONNECTIONS)).not.toHaveClass(/phx-hook-loading/)
  await expect(page.locator(REFUSAL)).toBeVisible()
  await expect.poll(() => moved(page, REFUSAL)).toBe(true)
  await expect.poll(() => leftovers(page)).toEqual([])
  expect(await page.locator(REFUSAL).getAttribute("style")).toBeNull()
})

test("a reader who asked for less motion sees refusals and cards without movement", async ({browser}) => {
  const context = await browser.newContext({reducedMotion: "reduce"})
  const page = await context.newPage()

  await openConnections(page)
  await refuseConnection(page)
  await expect(page.locator(REFUSAL)).toBeVisible()
  await page.waitForTimeout(600)
  expect(await anythingMoved(page), "a refusal").toBe(false)

  await page.goto("/")
  await expect(page.locator(".phx-connected").first()).toBeAttached()
  await page.waitForTimeout(600)
  expect(await anythingMoved(page), "the homepage").toBe(false)
  await context.close()
})
