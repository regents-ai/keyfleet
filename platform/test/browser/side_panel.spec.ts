import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"

// Invariants covered:
// - on a wide screen the side panel opens beside the page from the header, the
//   page gives it room, it stays open across pages and a reload, and Escape
//   closes it and returns focus to the header's button
// - Pair New Agent on the Account page opens the panel at its pairing box
// - on the homepage on a wide screen the panel opens under the header beside
//   the page, which narrows so nothing sits under the panel, and Manage Account
//   opens the account page in the same tab (Sean, 21 October 2026: "the
//   sidebar should not cover content, it should shorten the visible area")
// - between a phone and a wide screen the panel stands beside the menu strip
//   and the page, which both narrow for it
// - on a phone the panel covers the page under the header, and a panel left
//   open never opens on arrival, only on a press
// - on the homepage on a phone a link in the panel closes it; Fleets beside
//   the name opens Classic's page

async function signIn(page: Page) {
  const auth = await installAuthenticatedPrivy(page, "valid")
  await auth.establishLocalSession()
}

const panel = (page: Page) => page.locator("#shell-aside")
const panelButton = (page: Page) => page.getByRole("button", {name: "Side panel"})

test("on a wide screen the side panel opens beside the page and is remembered", async ({page}) => {
  await signIn(page)
  await page.goto("/account")
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
  await expect(panel(page)).toBeHidden()
  const pageWidth = () => page.locator("#app-shell-scroller").evaluate(scroller => scroller.clientWidth)
  const closedWidth = await pageWidth()

  await panelButton(page).click()
  await expect(panel(page)).toBeVisible()
  await expect(panelButton(page)).toHaveAttribute("aria-expanded", "true")
  await expect(page.locator("#account-chip")).toHaveAttribute("aria-expanded", "true")
  await expect(panel(page).getByRole("heading", {name: "Your agents"})).toBeVisible()
  await expect(panel(page).getByRole("heading", {name: "Pair New Agent"})).toBeVisible()
  await expect.poll(pageWidth).toBeLessThan(closedWidth)

  await page.locator("#shell-sidebar a[href='/classic/1']").click()
  await expect(page).toHaveURL(/\/classic\/1$/)
  await expect(panel(page)).toBeVisible()
  await page.reload()
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
  await expect(panel(page)).toBeVisible()
  await expect(panelButton(page)).toHaveAttribute("aria-expanded", "true")

  await panel(page).getByRole("heading", {name: "Pair New Agent"}).click()
  await page.keyboard.press("Escape")
  await expect(panel(page)).toBeHidden()
  await expect(panelButton(page)).toBeFocused()
  await expect(panelButton(page)).toHaveAttribute("aria-expanded", "false")
  await expect.poll(pageWidth).toBe(closedWidth)

  await page.goto("/account")
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
  await expect(panel(page)).toBeHidden()
  await page.locator("#account-page").getByRole("button", {name: "Pair New Agent"}).click()
  await expect(page.locator("#shell-pairing")).toBeInViewport()
})

test("on the homepage the side panel sits beside the page, and Manage Account opens the account page", async ({page}) => {
  await signIn(page)
  await page.goto("/")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  const content = page.locator("#public-home > main")
  const closedWidth = (await content.boundingBox())!.width

  await panelButton(page).click()
  await expect(panel(page)).toBeVisible()
  await expect.poll(async () => (await content.boundingBox())!.width).toBeLessThan(closedWidth)
  // Once it has slid in, its right edge is the header's.
  const header = (await page.locator("#shell-header").boundingBox())!
  await expect
    .poll(async () => Math.round((await panel(page).boundingBox())!.x + (await panel(page).boundingBox())!.width))
    .toBe(Math.round(header.x + header.width))
  const box = (await panel(page).boundingBox())!
  const main = (await content.boundingBox())!
  expect(Math.round(box.y)).toBe(Math.round(header.y + header.height))
  expect(main.x + main.width).toBeLessThanOrEqual(box.x + 1)

  // Scrolled down, the header and the panel stay put beside the page.
  await page.mouse.wheel(0, 1200)
  await expect.poll(async () => Math.round((await panel(page).boundingBox())!.y)).toBe(
    Math.round((await page.locator("#shell-header").boundingBox())!.height),
  )

  await panel(page).getByRole("link", {name: "Manage Account"}).click()
  await expect(page).toHaveURL(/\/account$/)
  await expect(page.locator("#account-page")).toBeVisible()
  await expect(panel(page)).toBeVisible()
})

test("between a phone and a wide screen the side panel stands beside the menu strip and the page", async ({page}) => {
  await page.setViewportSize({width: 820, height: 900})
  await signIn(page)
  await page.goto("/account")
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")

  await panelButton(page).click()
  await expect(panel(page)).toBeVisible()
  await expect.poll(async () => Math.round((await panel(page).boundingBox())!.x)).toBe(820 - 320)
  const header = (await page.locator("#shell-header").boundingBox())!
  const strip = (await page.locator("#shell-sidebar").boundingBox())!
  const scroller = (await page.locator("#app-shell-scroller").boundingBox())!
  const box = (await panel(page).boundingBox())!
  expect(Math.round(header.width)).toBe(820)
  expect(Math.round(box.y)).toBe(Math.round(header.y + header.height))
  expect(Math.round(strip.y)).toBe(Math.round(header.y + header.height))
  expect(strip.x + strip.width).toBeLessThanOrEqual(box.x + 1)
  expect(scroller.y).toBeGreaterThanOrEqual(strip.y + strip.height - 1)
  expect(scroller.x + scroller.width).toBeLessThanOrEqual(box.x + 1)
})

test.describe("on a phone", () => {
  test.use({viewport: {width: 375, height: 812}})

  test("the side panel covers the page and opens only on a press", async ({page}) => {
    await signIn(page)
    await page.goto("/account")
    await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")

    await page.locator("#account-chip").click()
    await expect(panel(page)).toBeVisible()
    // Once it has slid in, it runs from the screen's left edge.
    await expect.poll(async () => Math.round((await panel(page).boundingBox())!.x)).toBe(0)
    const header = (await page.locator("#shell-header").boundingBox())!
    const box = (await panel(page).boundingBox())!
    expect(Math.round(box.y)).toBe(Math.round(header.y + header.height))
    expect(Math.round(box.width)).toBe(375)
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(375)

    // Remembered open, the next page still arrives with it closed.
    await page.reload()
    await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
    await expect(panel(page)).toBeHidden()
    await panelButton(page).click()
    await expect(panel(page)).toBeVisible()
  })

  test("on the homepage the side panel covers the page, a link in it closes it, and Fleets opens Classic", async ({page}) => {
    await signIn(page)
    await page.goto("/")
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
    await expect(panel(page)).toBeHidden()

    await panelButton(page).click()
    await expect(panel(page)).toBeVisible()
    const header = (await page.locator("#shell-header").boundingBox())!
    expect(Math.round((await panel(page).boundingBox())!.y)).toBe(Math.round(header.y + header.height))

    await panel(page).getByRole("link", {name: "Manage Account"}).click()
    await expect(page).toHaveURL(/\/account$/)
    await expect(panel(page)).toBeHidden()

    await page.goto("/")
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
    await page.locator("#shell-header").getByRole("link", {name: "Fleets"}).click()
    await expect(page).toHaveURL(/\/classic\/1$/)
  })
})
