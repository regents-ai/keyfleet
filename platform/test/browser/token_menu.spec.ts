import {expect, test, type Page} from "@playwright/test"

// The crown in the header opens the $REGENT menu, as regents.sh's does:
// "$REGENT" copies the token's address, then Buy on Uniswap and View Chart.
const address = "0x6f89bcA4eA5931EdFCB09786267b251DeE752b07"
const buy = `https://app.uniswap.org/explore/tokens/base/${address}`
const chart = "https://dexscreener.com/base/0x4ed3b69ac263ad86482f609b2c2105f64bcfd3a7e02e8e078ec9fec1f0324bed"

test.use({permissions: ["clipboard-read", "clipboard-write"]})

// The Classic page, in the theme asked for, as the visitor's chosen theme.
async function open(page: Page, theme: "light" | "dark" = "light") {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  await page.goto("/healthz")
  await page.context().addCookies([{name: "regent_theme", value: theme, url: page.url()}])
  await page.goto("/classic/1")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  await expect(page.locator("html")).toHaveAttribute("data-theme", theme)
  return errors
}

const menu = (page: Page) => page.locator("#shell-regents-crown")
const crown = (page: Page) => page.locator("#shell-regents-crown > summary")
const panel = (page: Page) => page.locator("#shell-regents-crown .rl-token-menu-content")

test("the crown's menu holds $REGENT, Buy on Uniswap and View Chart", async ({page}) => {
  const errors = await open(page)
  await expect(panel(page)).toBeHidden()
  await expect(crown(page)).toHaveAccessibleName("$REGENT links")

  await crown(page).hover()
  await expect(panel(page)).toBeVisible()
  const copy = panel(page).getByRole("button", {name: "Copy $REGENT contract address"})
  await expect(copy.locator(".rg-copy__idle")).toHaveText("$REGENT")
  const links = panel(page).getByRole("link")
  await expect(links).toHaveText(["Buy on Uniswap", "View Chart"])
  for (const [name, href] of [
    ["Buy on Uniswap", buy],
    ["View Chart", chart],
  ]) {
    const link = panel(page).getByRole("link", {name})
    await expect(link).toHaveAttribute("href", href)
    await expect(link).toHaveAttribute("target", "_blank")
  }
  expect(errors).toEqual([])
})

test("a mouse opens it on hover and leaving shuts it", async ({page}) => {
  await open(page)
  await crown(page).hover()
  await expect(menu(page)).toHaveJSProperty("open", true)
  // Down onto the panel keeps it open, across the gap under the crown.
  await panel(page).getByRole("link", {name: "View Chart"}).hover()
  await expect(menu(page)).toHaveJSProperty("open", true)
  await page.mouse.move(5, 400)
  await expect(menu(page)).toHaveJSProperty("open", false)
})

test("$REGENT copies the token's address", async ({page}) => {
  await open(page)
  await page.evaluate(() => navigator.clipboard.writeText(""))
  await crown(page).hover()
  const copy = page.locator("#shell-regents-crown-copy")
  await copy.click()
  await expect(copy).toHaveAttribute("data-copy-state", "copied")
  await expect(page.locator("#shell-regents-crown-copy-status")).toHaveText("Copied")
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(address)
})

test("the keyboard opens it, Escape shuts it and hands focus back to the crown", async ({page}) => {
  await open(page)
  await crown(page).focus()
  await page.keyboard.press("Enter")
  await expect(panel(page)).toBeVisible()
  await page.keyboard.press("Tab")
  await expect(page.locator("#shell-regents-crown-copy")).toBeFocused()
  await page.keyboard.press("Escape")
  await expect(panel(page)).toBeHidden()
  await expect(crown(page)).toBeFocused()
})

test.describe("on a touch screen", () => {
  test.use({hasTouch: true})

  test("a tap opens it and a tap elsewhere shuts it", async ({page}) => {
    await open(page)
    await crown(page).tap()
    await expect(panel(page)).toBeVisible()
    await page.locator("main").tap({position: {x: 10, y: 10}})
    await expect(panel(page)).toBeHidden()
  })
})

// The panel takes the page's own surface and ink, so it reads in both themes,
// and the two links are Tangerine on it.
for (const theme of ["light", "dark"] as const) {
  test(`in ${theme}, the panel is the page's surface with Tangerine links`, async ({page}) => {
    await open(page, theme)
    await crown(page).hover()
    await expect(panel(page)).toBeVisible()
    const look = await page.evaluate(() => {
      // A colour as the browser writes it once computed, so both sides compare alike.
      const probe = (property: "color" | "backgroundColor", value: string) => {
        const span = document.createElement("span")
        span.style[property] = value
        document.body.append(span)
        const color = getComputedStyle(span)[property]
        span.remove()
        return color
      }
      const content = document.querySelector("#shell-regents-crown .rl-token-menu-content")!
      const link = content.querySelector("a")!
      const copy = content.querySelector("button")!
      return {
        panel: getComputedStyle(content).backgroundColor,
        surface: probe("backgroundColor", "var(--color-surface)"),
        ink: getComputedStyle(copy).color,
        fg: probe("color", "var(--color-fg)"),
        link: getComputedStyle(link).color,
        tangerine: probe("color", "var(--palette-tangerine-tango)"),
      }
    })
    expect(look.panel).toBe(look.surface)
    expect(look.ink).toBe(look.fg)
    expect(look.link).toBe(look.tangerine)
  })
}
