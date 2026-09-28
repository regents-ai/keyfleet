import {expect, test, type Page} from "@playwright/test"
import {
  installAuthenticatedPrivy,
  matchesAuthenticatedPrivyBridgeUrl,
} from "./support/authenticated_privy"

// The first fleet's page stands for every fleet's page.
const fleetPath = "/app/fleets/fibonacci_syndicate"
const shellRoutes = [fleetPath, "/account"]

// The shell holds one live session across every page, so a link to another page
// patches the page it is already on. Content links do this in the product; the test
// raises one so the patch can be exercised from any route.
async function patchTo(page: Page, path: string) {
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

  await page.locator("#patch-probe").click()
}

// Actual ruled-frame surfaces replace all page-background masks.
function readFamily(page: Page) {
  return page.evaluate(() => {
    const shell = document.querySelector("#app-shell")
    return {
      ground: shell && getComputedStyle(shell).backgroundColor,
      text: shell && getComputedStyle(shell).color,
    }
  })
}

async function chooseTheme(page: Page, choice: "light" | "dark") {
  await page.goto("/account")
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
  if ((await page.locator("html").getAttribute("data-theme")) !== choice) {
    await page.locator("#theme-control [data-theme-toggle]").click()
  }
  await expect(page.locator("html")).toHaveAttribute("data-theme", choice)
}

test("the ruled shell keeps one palette across pages", async ({page}) => {
  const palette: Record<string, {ground: string | null; text: string | null}> = {}
  for (const choice of ["light", "dark"] as const) {
    await chooseTheme(page, choice)
    for (const route of shellRoutes) {
      await page.goto(route)
      await expect(page.locator("html")).toHaveAttribute("data-theme", choice)
      await expect(page.locator("html")).toHaveAttribute("data-brand", "platform")
      await expect(page.locator(".shell-background, .shell-background__asset")).toHaveCount(0)
      await expect(page.locator("#app-shell")).toHaveClass(/rg-frame/)
      const colors = await readFamily(page)
      palette[choice] ??= colors
      expect(colors).toEqual(palette[choice])
    }
    await page.goto("/account")
    await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
    for (const destination of [fleetPath, "/account"]) {
      await patchTo(page, destination)
      await expect(page).toHaveURL(new RegExp(`${destination}$`))
      await expect.poll(() => readFamily(page)).toEqual(palette[choice])
    }
  }
  expect(palette.light).not.toEqual(palette.dark)
})

test("direct page loads seed the canonical RegentUI brand", async ({
  page,
  request,
}) => {
  for (const [route, brand] of [
    [fleetPath, "platform"],
    ["/account", "platform"],
  ] as const) {
    const served = await (await request.get(route)).text()
    expect(served).toContain(`data-brand="${brand}"`)
    expect(served).toContain('data-theme="dark"')

    await page.goto(route)
    await expect(page.locator("html")).toHaveAttribute("data-brand", brand)
    await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
  }
})

test("page headings use canonical Pixel Square", async ({page}) => {
  await page.goto("/account")
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")

  expect(
    await page
      .locator(".account-heading h1")
      .evaluate(element => getComputedStyle(element).fontFamily),
  ).toContain("Geist Pixel Square")
})

test("all approved routes render within their page budget", async ({page, request}) => {
  const home = await request.get("/")
  expect(home.status()).toBe(200)
  expect((await home.body()).byteLength).toBeLessThanOrEqual(100 * 1024)

  for (const route of shellRoutes) {
    const response = await request.get(route)
    expect(response.status(), route).toBe(200)
    expect((await response.body()).byteLength, route).toBeLessThanOrEqual(100 * 1024)
  }

  await page.goto("/account")
  await expect(page.locator("#app-shell")).toBeVisible()
})

test("anonymous Sign In stays separate from the brand link", async ({page}) => {
  await page.goto("/account")
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")

  const brand = page.locator("#shell-brand")
  const accountControl = page.locator("#account-control")

  await expect(brand).toContainText("Keyfleet")
  await expect(brand).toHaveAttribute("href", "/")
  await expect(brand.getByRole("button")).toHaveCount(0)
  await expect(accountControl.getByRole("button", {name: "Sign In"})).toBeVisible()
  await expect(accountControl.getByRole("link")).toHaveCount(0)
})

test("a signed-in account shows its account menu", async ({page}) => {
  const ashOrigin = "http://127.0.0.1:4002"
  const hashedBridge = "privy_bridge-0123456789abcdef0123456789abcdef.js"
  expect(
    matchesAuthenticatedPrivyBridgeUrl(
      `${ashOrigin}/assets/js/privy_bridge.js?regent_retry=1`,
      ashOrigin,
    ),
  ).toBe(true)
  expect(
    matchesAuthenticatedPrivyBridgeUrl(
      `${ashOrigin}/assets/js/${hashedBridge}?vsn=d&regent_retry=2`,
      ashOrigin,
    ),
  ).toBe(true)
  expect(
    matchesAuthenticatedPrivyBridgeUrl(
      "https://attacker.example/assets/js/privy_bridge.js?regent_retry=1",
      ashOrigin,
    ),
  ).toBe(false)
  expect(
    matchesAuthenticatedPrivyBridgeUrl(
      `https://attacker.example/assets/js/${hashedBridge}?vsn=d&regent_retry=2`,
      ashOrigin,
    ),
  ).toBe(false)
  expect(
    matchesAuthenticatedPrivyBridgeUrl(
      `${ashOrigin}/assets/js/privy_bridge.js?authenticated_privy_original=1`,
      ashOrigin,
    ),
  ).toBe(false)

  const auth = await installAuthenticatedPrivy(page, "valid")
  await auth.establishLocalSession()

  await page.goto("/account")
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
  await expect(page.locator("#theme-control [data-theme-toggle]")).toBeVisible()
  await auth.expectAuthenticatedSession()
  await auth.expectCounts({documents: 1, sessionChecks: 1, syncs: 1})

  const account = page.locator("#account-menu")
  await expect(account.locator("img.account-avatar")).toHaveAttribute(
    "src",
    /^data:image\/svg\+xml;base64,/,
  )
  await expect
    .poll(() => account.locator("img.account-avatar").evaluate(image => image.naturalWidth))
    .toBeGreaterThan(0)
  await account.locator("summary").first().click()
  await expect(account.locator(".account-menu__row")).toHaveText(["Account", "Disconnect"])
  await expect(account.getByRole("link", {name: "Account", exact: true})).toHaveAttribute(
    "href",
    "/account",
  )
  await expect(account.getByRole("button", {name: "Disconnect"})).toBeVisible()

  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark")
  await page.locator("#theme-control [data-theme-toggle]").click()
  await expect(page.locator("html")).toHaveAttribute("data-theme", "light")
  expect(await page.evaluate(() => document.cookie)).toContain("regent_theme=light")

  await page.reload()
  await expect(page.locator("html")).toHaveAttribute("data-theme", "light")
  await auth.expectAuthenticatedSession()
  await auth.expectCounts({documents: 2, sessionChecks: 2, syncs: 2})
})

test("the sidebar lists the four fleets, Classic first, then the Account page", async ({page}) => {
  await page.goto(fleetPath)
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
  await expect(page.getByRole("heading", {level: 1, name: "Keyfleet Syndicate"})).toBeVisible()

  const sidebar = page.locator("#shell-sidebar")
  const links = await sidebar.locator("a[href^='/app/fleets/'], a[href='/account']").evaluateAll(elements =>
    elements.map(element => [element.textContent?.trim(), element.getAttribute("href")]),
  )
  expect(links).toEqual([
    ["Keyfleet Classic", "/app/fleets/fleet_tech_classic"],
    ["Keyfleet Syndicate", "/app/fleets/fibonacci_syndicate"],
    ["Keyfleet Cascade", "/app/fleets/fibonacci_cascade"],
    ["Keyfleet Accelerant", "/app/fleets/fleet_tech_accelerant"],
    ["Account", "/account"],
  ])

  await sidebar.getByRole("link", {name: "Account"}).click()
  await expect(page).toHaveURL(/\/account$/)
  await expect(page.locator("#account-page").getByRole("heading", {level: 1, name: "Account"})).toBeVisible()
  await expect(page.getByRole("heading", {level: 2, name: "Sign in to see your account"})).toBeVisible()
})

test("navigation keeps brand, document, shell identity, and starts at the top", async ({page}) => {
  await page.goto(fleetPath)
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
  await expect(page.locator("html")).toHaveAttribute("data-brand", "platform")
  const shellInstance = await page.locator("#app-shell").getAttribute("data-shell-instance")
  await page.evaluate(() => {
    ;(window as Window & {shellDocument?: object}).shellDocument = {}
    const content = document.querySelector("#route-content")
    content?.insertAdjacentHTML("beforeend", '<div style="height:2000px"></div>')
    document.querySelector("#app-shell-scroller")?.scrollTo(0, 1000)
  })

  await patchTo(page, "/account")
  await expect(page).toHaveURL(/\/account$/)
  await expect(page.locator("html")).toHaveAttribute("data-brand", "platform")
  await expect(page.locator("#app-shell")).toHaveAttribute("data-shell-instance", shellInstance ?? "")

  expect(
    await page.evaluate(() => Boolean((window as Window & {shellDocument?: object}).shellDocument)),
  ).toBe(true)
  expect(await page.locator("#app-shell-scroller").evaluate(element => element.scrollTop)).toBe(0)

  await patchTo(page, fleetPath)
  await expect(page).toHaveURL(/\/app\/fleets\/fibonacci_syndicate$/)
  await expect(page.locator("html")).toHaveAttribute("data-brand", "platform")
  await page.evaluate(() => {
    document
      .querySelector("#route-content")
      ?.insertAdjacentHTML("beforeend", '<div style="height:2000px"></div>')
    document.querySelector("#app-shell-scroller")?.scrollTo(0, 1000)
  })

  await page.goBack()
  await expect(page).toHaveURL(/\/account$/)
  await expect(page.locator("html")).toHaveAttribute("data-brand", "platform")
  await expect(page.locator("#app-shell")).toHaveAttribute("data-shell-instance", shellInstance ?? "")
  expect(await page.locator("#app-shell-scroller").evaluate(element => element.scrollTop)).toBe(0)

  await page.evaluate(() => {
    document
      .querySelector("#route-content")
      ?.insertAdjacentHTML("beforeend", '<div style="height:2000px"></div>')
    document.querySelector("#app-shell-scroller")?.scrollTo(0, 1000)
  })
  await page.goForward()
  await expect(page).toHaveURL(/\/app\/fleets\/fibonacci_syndicate$/)
  await expect(page.locator("html")).toHaveAttribute("data-brand", "platform")
  await expect(page.locator("#app-shell")).toHaveAttribute("data-shell-instance", shellInstance ?? "")
  expect(await page.locator("#app-shell-scroller").evaluate(element => element.scrollTop)).toBe(0)
})

test("rapid page switches leave the latest page at rest", async ({page}) => {
  await page.goto(fleetPath)
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")

  await patchTo(page, "/account")
  await expect(page).toHaveURL(/\/account$/)
  await patchTo(page, fleetPath)

  await expect(page).toHaveURL(/\/app\/fleets\/fibonacci_syndicate$/)
  await expect(page.getByRole("heading", {level: 1, name: "Keyfleet Syndicate"})).toBeVisible()
  await expect(page.locator("#route-content")).toHaveCSS("opacity", "1")
  for (const region of ["#route-content", "#shell-sidebar"]) {
    await expect(page.locator(region), `${region} is left to the stylesheet`).not.toHaveAttribute("style")
  }
})

test("the theme preference applies immediately", async ({page}) => {
  await page.goto("/account")
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")

  // With nothing saved the server renders the dark theme, and the switch says so
  // before it is touched.
  const toggle = page.locator("#theme-control [data-theme-toggle]")
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark")
  await expect(toggle).toHaveAttribute("aria-pressed", "false")
  await expect(toggle).toHaveAttribute(
    "aria-label",
    "Color theme: Dark. Activate Light theme.",
  )
  await expect(toggle.locator("[data-theme-toggle-state]")).toHaveText("Dark theme active")

  await toggle.click()
  await expect(page.locator("html")).toHaveAttribute("data-theme", "light")
  await expect(toggle).toHaveAttribute("aria-pressed", "true")
  await expect(toggle.locator("[data-theme-toggle-state]")).toHaveText("Light theme active")

  await page.reload()
  await expect(page.locator("html")).toHaveAttribute("data-theme", "light")
  await expect(toggle).toHaveAttribute("aria-pressed", "true")

  await toggle.click()
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark")
  await page.reload()
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark")
})

for (const width of [320, 390]) {
  test(`${width}px drawer contains focus and cleans up every close path`, async ({page}) => {
    await page.setViewportSize({width, height: 720})
    await page.goto("/account")
    await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")

    const menu = page.getByRole("button", {name: "Menu"})
    const sidebar = page.getByRole("navigation", {name: "Context navigation"})
    const scrim = page.locator("[data-shell-menu-scrim]")
    const scroller = page.locator("#app-shell-scroller")

    await menu.click()
    await expect(menu).toHaveAttribute("aria-expanded", "true")
    await expect(sidebar).toBeVisible()
    await expect(scrim).toBeVisible()
    await expect(scroller).toHaveAttribute("inert", "")
    expect(await sidebar.evaluate(element => element.contains(document.activeElement))).toBe(true)

    await page.keyboard.press("Shift+Tab")
    expect(await sidebar.evaluate(element => element.contains(document.activeElement))).toBe(true)
    await page.keyboard.press("Tab")
    expect(await sidebar.evaluate(element => element.contains(document.activeElement))).toBe(true)

    await page.keyboard.press("Escape")
    await expect(menu).toHaveAttribute("aria-expanded", "false")
    await expect(menu).toBeFocused()
    await expect(scrim).toBeHidden()
    await expect(scroller).not.toHaveAttribute("inert", "")

    await menu.click()
    await scrim.click({position: {x: width - 2, y: 10}})
    await expect(menu).toHaveAttribute("aria-expanded", "false")
    await expect(menu).toBeFocused()

    await menu.click()
    await sidebar.getByRole("button", {name: "Close navigation"}).click()
    await expect(menu).toHaveAttribute("aria-expanded", "false")
    await expect(menu).toBeFocused()

    await menu.click()
    const destination = sidebar.locator('a[href]:not([href="/account"])').first()
    await destination.click()
    await expect(menu).toHaveAttribute("aria-expanded", "false")
    await expect(scrim).toBeHidden()
    await expect(scroller).not.toHaveAttribute("inert", "")

    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
    await expect(page.getByRole("banner")).toHaveCount(1)
    await expect(page.getByRole("main")).toHaveCount(1)
  })
}

test("tablet, desktop, and effective 200 percent zoom have no horizontal overflow", async ({page}) => {
  for (const viewport of [
    {width: 768, height: 1024},
    {width: 1280, height: 800},
    {width: 640, height: 900},
  ]) {
    await page.setViewportSize(viewport)
    await page.goto("/account")
    await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(
      viewport.width,
    )
  }
})
