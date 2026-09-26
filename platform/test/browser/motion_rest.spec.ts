import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {forget, leftovers, moved, pageChangeMoved, pressRapidly, watchMotion} from "./support/motion"

// However fast a reader presses, every move ends at rest: a move begun over
// another's half-way frame still hands its element back to the stylesheet
// with no inline transform or opacity left. A page changed from the keyboard,
// or for a reader who asked for less motion, shows at once every time.

const fleetPath = "/app/fleets/fibonacci_syndicate"

async function openFleet(page: Page) {
  await watchMotion(page)
  await page.goto(fleetPath)
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
  await forget(page)
}

// Moves settle within half a second; this waits well past the last one.
const settle = (page: Page) => page.waitForTimeout(1_000)

// The shell keeps one live session across pages, so a link to another page
// patches the one it is on, as the sidebar's links do.
async function patchTo(page: Page, path: string, by: "pointer" | "keyboard" = "pointer") {
  await page.evaluate(destination => {
    document.querySelector("#patch-probe")?.remove()
    const link = document.createElement("a")
    link.id = "patch-probe"
    link.href = destination
    link.textContent = destination
    link.dataset.phxLink = "patch"
    link.dataset.phxLinkState = "push"
    document.querySelector("#route-content")?.append(link)
  }, path)
  if (by === "pointer") await page.locator("#patch-probe").click()
  else await page.locator("#patch-probe").press("Enter")
  await expect(page).toHaveURL(new RegExp(`${path}$`))
}

test("a panel button pressed again and again mid-move leaves the button and its panel at rest", async ({page}) => {
  await openFleet(page)

  await pressRapidly(page, "#fleet-about-toggle")
  await settle(page)

  expect(await moved(page, "#fleet-about-toggle")).toBe(true)
  expect(await moved(page, "#fleet-about")).toBe(true)
  expect(await leftovers(page)).toEqual([])
})

test("a menu opened and closed again and again mid-move leaves the menu at rest", async ({page}) => {
  await openFleet(page)

  await pressRapidly(page, "#fleet-rooms-toggle")
  await settle(page)

  expect(await moved(page, "#fleet-rooms")).toBe(true)
  expect(await leftovers(page)).toEqual([])
})

test("the account menu opened and closed again and again mid-move ends at rest", async ({page}) => {
  const auth = await installAuthenticatedPrivy(page, "valid")
  await auth.establishLocalSession()
  await watchMotion(page)
  await page.goto("/account")
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
  await auth.expectAuthenticatedSession()
  await forget(page)

  await pressRapidly(page, "#account-menu summary")
  await settle(page)

  expect(await moved(page, "#account-menu .account-menu__content")).toBe(true)
  expect(await leftovers(page)).toEqual([])
})

test("a refused copy shakes over the press's squish and still ends at rest", async ({page}) => {
  await page.addInitScript(() => {
    navigator.clipboard.writeText = () => Promise.reject(new DOMException("Refused", "NotAllowedError"))
  })
  await watchMotion(page)
  await page.goto("/")
  await expect(page.locator(".phx-connected").first()).toBeAttached()
  await forget(page)

  await pressRapidly(page, "#home-instruction-copy")
  await settle(page)

  expect(await moved(page, "#home-instruction-copy")).toBe(true)
  expect(await leftovers(page)).toEqual([])
})

test("a pointer's page change moves the page arriving", async ({page}) => {
  await openFleet(page)

  await patchTo(page, "/account")

  await expect.poll(() => pageChangeMoved(page)).toBe(true)
})

test("a keyboard's page change shows the page arriving at once", async ({page}) => {
  await openFleet(page)

  for (const path of ["/account", fleetPath]) {
    await patchTo(page, path, "keyboard")
    await settle(page)
    expect(await pageChangeMoved(page), `the change to ${path}`).toBe(false)
  }
})

test("a reader who asked for less motion sees no page change move, however many pages they visit", async ({
  browser,
}) => {
  const context = await browser.newContext({reducedMotion: "reduce"})
  const page = await context.newPage()
  await openFleet(page)

  for (const path of ["/account", fleetPath, "/account", fleetPath]) {
    await patchTo(page, path)
    await settle(page)
    expect(await pageChangeMoved(page), `the change to ${path}`).toBe(false)
  }
  await context.close()
})
