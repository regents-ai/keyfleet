import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"

// The light and dark switch (Shell.theme_toggle/1). It is a real switch named
// Light theme, on for the light theme, and a page shows exactly one: a row of the
// account menu signed in; signed out, in the header of the homepage and the app's
// pages, and in the footer of a reading page. A press, Space or Enter turns the
// page's theme exactly once; the choice holds over a reload and a live page
// change; opening the menu moves nothing and turning the switch never changes the
// menu's size; nothing scrolls sideways, at 320 wide included.

const html = (page: Page) => page.locator("html")
const switches = (page: Page) => page.getByRole("switch", {name: "Light theme"})
const menu = (page: Page) => page.locator("#account-menu")

// Errors the page throws, for a walk to show none at its end.
function watchErrors(page: Page) {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  return errors
}

async function expectTheme(page: Page, theme: "light" | "dark") {
  await expect(html(page)).toHaveAttribute("data-theme", theme)
  await expect(switches(page).filter({visible: true})).toHaveAttribute("aria-checked", String(theme === "light"))
}

// One press turns the theme once: a second mount of the switch would hear the
// same press and turn it straight back.
async function turnsOnce(page: Page, press: () => Promise<void>, to: "light" | "dark") {
  await press()
  await expectTheme(page, to)
}

const noSidewaysScroll = (page: Page) =>
  page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)

async function openMenu(page: Page) {
  await page.locator("#account-chip").click()
  await expect(menu(page)).toBeVisible()
  await expect.poll(() => menu(page).evaluate(element => element.getAnimations().length)).toBe(0)
}

const size = async (page: Page) => {
  const box = (await menu(page).boundingBox())!
  return {width: box.width, height: box.height}
}

for (const width of [1280, 390, 320]) {
  test.describe(`${width}px wide`, () => {
    test.use({viewport: {width, height: 900}})

    // A reading page (its footer), an app page and the homepage (their header).
    for (const [path, ready] of [
      ["/docs", ".legal-page"],
      ["/account", "#app-shell[data-behavior-ready=true]"],
      ["/", "[data-phx-main].phx-connected"],
    ] as const) {
      test(`signed out, the switch on ${path} turns the theme once a press`, async ({page}) => {
        const errors = watchErrors(page)
        await page.goto(path)
        await expect(page.locator(ready)).toBeAttached()
        await expect(switches(page)).toHaveCount(1)
        const toggle = switches(page)
        await toggle.scrollIntoViewIfNeeded()
        await expect(toggle).toBeVisible()

        // Light until the visitor chooses.
        await expectTheme(page, "light")
        await turnsOnce(page, () => toggle.click(), "dark")
        await toggle.focus()
        await turnsOnce(page, () => page.keyboard.press("Space"), "light")
        await turnsOnce(page, () => page.keyboard.press("Enter"), "dark")
        expect(await noSidewaysScroll(page)).toBe(true)

        await page.reload()
        await expect(page.locator(ready)).toBeAttached()
        await expectTheme(page, "dark")
        expect(errors).toEqual([])
      })
    }

    test("signed in, the account menu's switch turns the theme, and the choice holds", async ({page}) => {
      const errors = watchErrors(page)
      const auth = await installAuthenticatedPrivy(page, "valid")
      await auth.establishLocalSession()
      await page.goto("/classic/1")
      await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
      // The menu's row is the only switch; the header has none.
      await expect(page.locator("#theme-control")).toHaveCount(0)
      await expect(switches(page)).toHaveCount(1)

      const content = page.locator("#route-content")
      const before = await content.boundingBox()
      await openMenu(page)
      expect(await content.boundingBox()).toEqual(before)
      const toggle = menu(page).getByRole("switch", {name: "Light theme"})
      await expectTheme(page, "light")
      const opened = await size(page)

      await turnsOnce(page, () => toggle.click(), "dark")
      await expect(menu(page)).toBeVisible()
      expect(await size(page)).toEqual(opened)

      await toggle.focus()
      await turnsOnce(page, () => page.keyboard.press("Space"), "light")
      await turnsOnce(page, () => page.keyboard.press("Enter"), "dark")
      expect(await size(page)).toEqual(opened)
      expect(await noSidewaysScroll(page)).toBe(true)

      await page.reload()
      await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
      await expect(html(page)).toHaveAttribute("data-theme", "dark")
      await openMenu(page)
      await expectTheme(page, "dark")

      // Manage Account is a live page change: the document stays and restates its theme.
      await menu(page).getByRole("link", {name: "Manage Account"}).click()
      await expect(page).toHaveURL(/\/account$/)
      await expect(page.locator("#account-page")).toBeVisible()
      await expect(html(page)).toHaveAttribute("data-theme", "dark")
      await openMenu(page)
      await expectTheme(page, "dark")
      await turnsOnce(page, () => toggle.click(), "light")
      expect(errors).toEqual([])
    })
  })
}
