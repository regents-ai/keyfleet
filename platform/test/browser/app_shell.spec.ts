import {expect, test, type Locator, type Page} from "@playwright/test"
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

// A press chooses the opposite of the theme showing, and before any choice the device
// decides what shows, so it may take a second press to land on the theme wanted.
async function chooseTheme(page: Page, choice: "light" | "dark") {
  await page.goto("/account")
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
  for (let press = 0; press < 2; press++) {
    if ((await page.locator("html").getAttribute("data-theme")) === choice) break
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
    // Nothing chosen yet, so the page carries no theme and follows the device.
    expect(served).not.toMatch(/<html[^>]*\sdata-theme=/)

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

  // Nothing chosen and a device that asks for dark: dark shows, so a press chooses light.
  await page.emulateMedia({colorScheme: "dark"})
  await expect(page.locator("html")).not.toHaveAttribute("data-theme", /.*/)
  await page.locator("#theme-control [data-theme-toggle]").click()
  await expect(page.locator("html")).toHaveAttribute("data-theme", "light")
  expect(await page.evaluate(() => document.cookie)).toContain("regent_theme=light")

  await page.reload()
  await expect(page.locator("html")).toHaveAttribute("data-theme", "light")
  await auth.expectAuthenticatedSession()
  await auth.expectCounts({documents: 2, sessionChecks: 2, syncs: 2})
})

const menuLinks = (section: Locator) =>
  section.locator("a").evaluateAll(elements =>
    elements.map(element => [element.textContent?.trim(), element.getAttribute("href")]),
  )

// How a menu link is drawn: its size, case, colour, cell line and active marker.
const linkLook = (link: Locator) =>
  link.evaluate(element => {
    const style = getComputedStyle(element)
    return {
      size: parseFloat(style.fontSize),
      transform: style.textTransform,
      color: style.color,
      rule: style.borderBottomWidth,
      marker: style.borderInlineStartWidth,
    }
  })

// The four fleets under their heading, then How it works and Account in a
// quieter group below a rule, on a desktop and on a phone, in both themes.
for (const viewport of [
  {name: "desktop", width: 1280, height: 800},
  {name: "phone", width: 375, height: 812},
]) {
  test(`the ${viewport.name} menu shows the fleets, then How it works and Account apart`, async ({page}) => {
    const phone = viewport.width < 768
    await page.setViewportSize(viewport)
    const colors: Record<string, string> = {}

    for (const theme of ["light", "dark"] as const) {
      await page.emulateMedia({colorScheme: theme})
      await page.goto(fleetPath)
      await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
      await expect(page.getByRole("heading", {level: 1, name: "Keyfleet Syndicate"})).toBeVisible()

      const menu = page.getByRole("button", {name: "Menu"})
      const sidebar = page.getByRole("navigation", {name: "Context navigation"})
      if (phone) {
        await expect(sidebar).toBeHidden()
        await menu.click()
      }
      await expect(sidebar).toBeVisible()

      const fleets = sidebar.getByRole("list", {name: "Fleets"})
      const site = sidebar.locator("[data-sidebar-section='site'] ul")
      await expect(sidebar.getByText("Fleets", {exact: true})).toBeVisible()
      expect(await menuLinks(fleets)).toEqual([
        ["Classic", "/app/fleets/fleet_tech_classic"],
        ["Syndicate", "/app/fleets/fibonacci_syndicate"],
        ["Cascade", "/app/fleets/fibonacci_cascade"],
        ["Accelerant", "/app/fleets/fleet_tech_accelerant"],
      ])
      expect(await menuLinks(site)).toEqual([
        ["How it works", "/how-it-works"],
        ["Account", "/account"],
      ])

      // Below the fleets, past a rule, in smaller sentence-case words with no cell lines.
      const fleetBox = (await fleets.boundingBox())!
      const siteBox = (await site.boundingBox())!
      expect(siteBox.y).toBeGreaterThan(fleetBox.y + fleetBox.height)
      expect(
        await sidebar
          .locator("[data-sidebar-section='site']")
          .evaluate(element => getComputedStyle(element).borderTopWidth),
      ).toBe("1px")
      const fleetLook = await linkLook(fleets.getByRole("link", {name: "Classic"}))
      const siteLook = await linkLook(site.getByRole("link", {name: "How it works"}))
      expect(fleetLook.transform).toBe("uppercase")
      expect(siteLook.transform).toBe("none")
      expect(siteLook.rule).toBe("0px")
      expect(fleetLook.rule).toBe("1px")
      expect(siteLook.color).toBe(fleetLook.color)
      colors[theme] = siteLook.color

      // Keyboard order: the fleets, then the lower group.
      if (!phone) await fleets.getByRole("link", {name: "Classic"}).focus()
      const reached: string[] = []
      for (let press = 0; press < (phone ? 7 : 6); press++) {
        const label = await page.evaluate(() => document.activeElement?.textContent?.trim() ?? "")
        if (label !== "Close navigation") reached.push(label)
        await page.keyboard.press("Tab")
      }
      expect(reached).toEqual(["Classic", "Syndicate", "Cascade", "Accelerant", "How it works", "Account"])

      // How it works opens inside the app with the menu beside it, marked as the
      // page open the same way a fleet is.
      await site.getByRole("link", {name: "How it works"}).click()
      await expect(page).toHaveURL(/\/how-it-works$/)
      await expect(page.locator("#how-it-works-page").getByRole("heading", {level: 1, name: "How Keyfleet works"})).toBeVisible()
      if (phone) {
        await expect(menu).toHaveAttribute("aria-expanded", "false")
        await expect(sidebar).toBeHidden()
        await menu.click()
      }
      const open = site.getByRole("link", {name: "How it works"})
      await expect(open).toHaveAttribute("aria-current", "page")
      expect((await linkLook(open)).marker).toBe("3px")
      await expect(fleets.locator("[aria-current]")).toHaveCount(0)

      await site.getByRole("link", {name: "Account"}).click()
      await expect(page).toHaveURL(/\/account$/)
      await expect(page.locator("#account-page").getByRole("heading", {level: 1, name: "Account"})).toBeVisible()
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(viewport.width)
    }
    expect(colors.light).not.toBe(colors.dark)
  })
}

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

// Before any choice the page carries no theme and follows the device, dark unless it asks
// for light; the switch names the theme showing either way. A press chooses the opposite,
// and the choice then wins over the device on every later page.
for (const device of ["dark", "light"] as const) {
  test(`with nothing chosen a ${device} device decides, and a choice sticks`, async ({page}) => {
    const other = device === "dark" ? "light" : "dark"
    const named = {
      dark: "Dark theme on. Switch to light theme.",
      light: "Light theme on. Switch to dark theme.",
    }
    const html = page.locator("html")
    const toggle = page.locator("#theme-control [data-theme-toggle]")

    await page.emulateMedia({colorScheme: device})
    await page.goto("/account")
    await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")

    await expect(html).not.toHaveAttribute("data-theme", /.*/)
    await expect(toggle).toHaveAccessibleName(named[device])
    expect(await page.evaluate(() => getComputedStyle(document.documentElement).colorScheme)).toBe(device)
    const unchosen = await readFamily(page)

    await toggle.click()
    await expect(html).toHaveAttribute("data-theme", other)
    await expect(toggle).toHaveAccessibleName(named[other])
    expect(await page.evaluate(() => document.cookie)).toContain(`regent_theme=${other}`)

    await page.reload()
    await expect(html).toHaveAttribute("data-theme", other)
    await expect(toggle).toHaveAccessibleName(named[other])
    expect(await page.evaluate(() => getComputedStyle(document.documentElement).colorScheme)).toBe(other)
    expect(await readFamily(page)).not.toEqual(unchosen)

    await toggle.click()
    await expect(html).toHaveAttribute("data-theme", device)
    await page.reload()
    await expect(html).toHaveAttribute("data-theme", device)
    await expect(toggle).toHaveAccessibleName(named[device])
    // The device's own theme, once chosen, is the same palette it showed unchosen.
    expect(await readFamily(page)).toEqual(unchosen)
  })
}

// The theme button is a small prism beside the X and GitHub icons, with no cell
// or rule of its own, 16px from the icons as they are from each other. Pointing
// at it shows the other theme's laser. On a phone the icons move to the footer.
for (const [layout, viewport] of [
  ["desktop", {width: 1280, height: 800}],
  ["phone", {width: 375, height: 812}],
] as const) {
  for (const scheme of ["light", "dark"] as const) {
    test(`${layout} ${scheme} header: the prism sits beside the icons`, async ({page}) => {
      await page.setViewportSize(viewport)
      // Reduced motion turns off the colour fade, so each colour read is final.
      await page.emulateMedia({colorScheme: scheme, reducedMotion: "reduce"})
      await page.goto("/account")
      await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")

      const toggle = page.locator("#theme-control [data-theme-toggle]")
      const stage = toggle.locator(".theme-toggle__stage")
      const laser = toggle.locator(".theme-toggle__laser")
      const box = (await stage.boundingBox())!
      expect(box.width).toBeCloseTo(28, 0)
      expect(box.height).toBeCloseTo(28, 0)
      expect(await toggle.evaluate(button => getComputedStyle(button).borderInlineStartWidth)).toBe("0px")

      const icons = page.locator("#shell-header .rl-header-links svg")
      if (layout === "desktop") {
        const [x, github] = [(await icons.nth(0).boundingBox())!, (await icons.nth(1).boundingBox())!]
        for (const icon of [x, github]) {
          expect(icon.width).toBeCloseTo(24, 0)
          expect(icon.height).toBeCloseTo(24, 0)
        }
        expect(x.x - (box.x + box.width)).toBeCloseTo(16, 0)
        expect(github.x - (x.x + x.width)).toBeCloseTo(16, 0)
      } else {
        await expect(icons.first()).toBeHidden()
      }

      const other = scheme === "light" ? "dark" : "light"
      const laserColour = () => laser.evaluate(element => getComputedStyle(element).backgroundColor)
      const stageColour = () => stage.evaluate(element => getComputedStyle(element).backgroundColor)
      const [resting, restingStage] = [await laserColour(), await stageColour()]
      await toggle.hover()
      await expect.poll(laserColour).not.toBe(resting)
      await expect.poll(stageColour).not.toBe(restingStage)
      const pointed = await laserColour()
      await page.mouse.move(0, viewport.height - 1)
      await expect.poll(laserColour).toBe(resting)
      await page.emulateMedia({colorScheme: other})
      await expect.poll(laserColour).toBe(pointed)

      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(viewport.width)
    })
  }
}

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
