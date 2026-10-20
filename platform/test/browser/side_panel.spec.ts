import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"

// Invariants covered:
// - on a wide screen the side panel opens beside the page from the header, the
//   page gives it room, it stays open across pages and a reload, and Escape
//   closes it and returns focus to the header's button
// - Pair New Agent on the Account page opens the panel at its pairing box
// - on a phone the panel covers the page under the header, and a panel left
//   open never opens on arrival, only on a press
// - on the homepage the panel covers the page from the header, and a link in
//   it closes it; Fleets beside the name opens Classic's page

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

test.describe("on a phone", () => {
  test.use({viewport: {width: 375, height: 812}})

  test("the side panel covers the page and opens only on a press", async ({page}) => {
    await signIn(page)
    await page.goto("/account")
    await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")

    await page.locator("#account-chip").click()
    await expect(panel(page)).toBeVisible()
    const header = (await page.locator("#shell-header").boundingBox())!
    const box = (await panel(page).boundingBox())!
    expect(Math.round(box.y)).toBe(Math.round(header.y + header.height))
    expect(box.width).toBe(375)
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(375)

    // Remembered open, the next page still arrives with it closed.
    await page.reload()
    await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
    await expect(panel(page)).toBeHidden()
    await panelButton(page).click()
    await expect(panel(page)).toBeVisible()
  })

  test("on the homepage the side panel covers the page, a link in it closes it, and Fleets opens Classic", async ({page}) => {
    await page.context().route("https://regents.sh/**", route => route.fulfill({body: "Account"}))
    await signIn(page)
    await page.goto("/")
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
    await expect(panel(page)).toBeHidden()

    await panelButton(page).click()
    await expect(panel(page)).toBeVisible()
    const header = (await page.locator("#shell-header").boundingBox())!
    expect(Math.round((await panel(page).boundingBox())!.y)).toBe(Math.round(header.y + header.height))

    const [manage] = await Promise.all([
      page.waitForEvent("popup"),
      panel(page).getByRole("link", {name: "Manage Account"}).click(),
    ])
    await manage.close()
    await expect(panel(page)).toBeHidden()

    await page.locator("#shell-header").getByRole("link", {name: "Fleets"}).click()
    await expect(page).toHaveURL(/\/classic\/1$/)
  })
})
