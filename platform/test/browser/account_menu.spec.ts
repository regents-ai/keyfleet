import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"

// Invariants covered, at 1280 and 390 wide, signed in:
// - the account's name at the top right opens the account menu, which hangs
//   under it inside the screen, holds the person's agents with Manage, Pair New
//   Agent, Manage Account and Sign out, and closes on Escape with focus back on
//   the name; Escape closes it before an open section behind it
// - Manage Account opens Keyfleet's Account page, with no agents, and the menu closes
// - Pair New Agent lands on the Agents page's pairing box with the keyboard on
//   the agent choice, again when pressed from the same address
// - on the homepage the same menu opens and Manage Account loads the Account page
// - on a phone, the open navigation menu makes the page behind it, footer
//   included, unreachable (inert), and closing it gives the page back

async function signIn(page: Page) {
  const auth = await installAuthenticatedPrivy(page, "valid")
  await auth.establishLocalSession()
}

const menu = (page: Page) => page.locator("#account-menu")

async function openShell(page: Page, path: string) {
  await page.goto(path)
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
}

async function openMenu(page: Page) {
  await page.locator("#account-chip").click()
  await expect(menu(page)).toBeVisible()
  await expect.poll(() => menu(page).evaluate(element => element.getAnimations().length)).toBe(0)
}

for (const width of [1280, 390]) {
  test.describe(`${width}px wide`, () => {
    test.use({viewport: {width, height: 900}})

    test("the account menu hangs under the name and closes on Escape", async ({page}) => {
      await signIn(page)
      await openShell(page, "/classic/1")
      await openMenu(page)

      const chip = (await page.locator("#account-chip").boundingBox())!
      const box = (await menu(page).boundingBox())!
      expect(box.y).toBeGreaterThanOrEqual(chip.y + chip.height - 1)
      expect(box.x).toBeGreaterThanOrEqual(0)
      // The chip ends at the screen edge, so whole pixels: layout can land 1/32 px past it.
      expect(Math.round(box.x + box.width)).toBeLessThanOrEqual(width)
      if (width > 390) expect(Math.abs(box.x + box.width - (chip.x + chip.width))).toBeLessThan(2)
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)

      await expect(menu(page).getByRole("heading", {name: "Your agents"})).toBeAttached()
      await expect(menu(page).getByRole("link", {name: "Manage your agents"})).toHaveAttribute(
        "href",
        "/account/agents",
      )
      await expect(menu(page).getByRole("link", {name: "Pair New Agent"})).toBeVisible()
      await expect(menu(page).getByRole("button", {name: "Sign out"})).toBeVisible()

      await menu(page).getByRole("link", {name: "Manage Account"}).focus()
      await page.keyboard.press("Escape")
      await expect(menu(page)).toBeHidden()
      await expect(page.locator("#account-chip")).toBeFocused()
    })

    test("Escape closes the account menu before an open section behind it", async ({page}) => {
      await signIn(page)
      await openShell(page, "/classic/1")
      await page.locator("#route-content").evaluate(content => {
        const details = document.createElement("details")
        details.open = true
        details.id = "walk-open-section"
        details.innerHTML = "<summary>Section</summary><p>Inside</p>"
        content.prepend(details)
      })
      await openMenu(page)
      await page.keyboard.press("Escape")
      await expect(menu(page)).toBeHidden()
      await expect(page.locator("#walk-open-section")).toHaveAttribute("open", "")
    })

    test("Manage Account opens the Account page and the menu closes", async ({page}) => {
      await signIn(page)
      await openShell(page, "/classic/1")
      await openMenu(page)
      await menu(page).getByRole("link", {name: "Manage Account"}).click()
      await expect(page).toHaveURL(/\/account$/)
      await expect(page.locator("#account-page")).toBeVisible()
      await expect(page.locator("#account-agents")).toHaveCount(0)
      await expect(menu(page)).toBeHidden()
    })

    test("Pair New Agent lands on the Agents page's pairing box", async ({page}) => {
      await signIn(page)
      await openShell(page, "/classic/1")
      await openMenu(page)
      await menu(page).getByRole("link", {name: "Pair New Agent"}).click()
      await expect(page).toHaveURL(/\/account\/agents#account-pairing$/)
      await expect(menu(page)).toBeHidden()
      const pairing = page.locator("#account-pairing")
      await expect(pairing).toBeInViewport()
      await expect(pairing.getByRole("radio").first()).toBeFocused()

      // Pressed again from the same address after leaving the box, it moves there again.
      // The Agents page can be short enough that the box never scrolls out of view,
      // so the keyboard moving back to the agent choice is what shows it.
      await page.locator("#app-shell-scroller").evaluate(scroller => scroller.scrollTo({top: 0}))
      await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur())
      await expect(pairing.getByRole("radio").first()).not.toBeFocused()
      await openMenu(page)
      await menu(page).getByRole("link", {name: "Pair New Agent"}).click()
      await expect(menu(page)).toBeHidden()
      await expect(pairing).toBeInViewport()
      await expect(pairing.getByRole("radio").first()).toBeFocused()

      // The Agents page's own Pair New Agent, beside the agents, goes there too.
      await page.locator("#app-shell-scroller").evaluate(scroller => scroller.scrollTo({top: 0}))
      await page.locator("#account-agents").getByRole("link", {name: "Pair New Agent"}).click()
      await expect(pairing).toBeInViewport()
    })

    test("on the homepage the account menu opens and Manage Account loads the Account page", async ({page}) => {
      await signIn(page)
      await page.goto("/")
      await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
      await openMenu(page)
      const box = (await menu(page).boundingBox())!
      expect(box.x + box.width).toBeLessThanOrEqual(width)
      await menu(page).getByRole("link", {name: "Manage Account"}).click()
      await expect(page).toHaveURL(/\/account$/)
      await expect(page.locator("#account-page")).toBeVisible()
    })
  })
}

test.describe("on a phone", () => {
  test.use({viewport: {width: 390, height: 844}})

  test("the open navigation menu makes the page and its footer unreachable", async ({page}) => {
    await signIn(page)
    await openShell(page, "/account")
    const scroller = page.locator("#app-shell-scroller")
    const footer = scroller.locator(".regent-footer")
    await expect(footer).toBeAttached()
    const insideInert = () => footer.evaluate(element => element.closest("[inert]") !== null)

    const navigation = page.getByRole("button", {name: "Menu"})
    await navigation.click()
    await expect(navigation).toHaveAttribute("aria-expanded", "true")
    await expect(scroller).toHaveAttribute("inert", "")
    expect(await insideInert()).toBe(true)

    await page.keyboard.press("Escape")
    await expect(navigation).toHaveAttribute("aria-expanded", "false")
    await expect(scroller).not.toHaveAttribute("inert", "")
    expect(await insideInert()).toBe(false)
  })
})
