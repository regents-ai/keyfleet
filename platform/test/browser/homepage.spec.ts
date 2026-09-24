import {expect, test, type Page} from "@playwright/test"

// The homepage chooses a fleet: a short hero over the crown, then one card per fleet,
// each with a still picture of its map, a sentence on how its keys sell, its sales
// so far, and a link into the map.

const fleets = [
  ["fibonacci_syndicate", "Keyfleet Syndicate", "fibonacci"],
  ["fibonacci_cascade", "Keyfleet Cascade", "fibonacci"],
  ["fleet_tech_classic", "Keyfleet Classic", "classic"],
  ["fleet_tech_accelerant", "Keyfleet Accelerant", "accelerant"],
] as const

const viewports = [
  {name: "desktop", width: 1440, height: 900},
  {name: "review-1024x768", width: 1024, height: 768},
  {name: "tablet-768", width: 768, height: 1024},
  {name: "mobile-390", width: 390, height: 844},
  {name: "mobile-320", width: 320, height: 720},
  {name: "short-landscape", width: 844, height: 390},
  {name: "zoom-200", width: 640, height: 900},
]

const waitForHomepage = async (page: Page) => {
  await expect(page.locator("#public-home")).toBeVisible()
  await page.evaluate(async () => {
    await document.fonts.ready
    await Promise.all([...document.images].filter(image => !image.complete).map(image => image.decode()))
  })
}

// Every card's picture is drawn once the page is live.
const waitForPreviews = (page: Page) =>
  expect
    .poll(() =>
      page.locator(".key-map-preview").evaluateAll(elements =>
        elements.map(element => element.querySelectorAll("svg polygon").length > 0),
      ),
    )
    .toEqual([true, true, true, true])

const assertNoOverflow = async (page: Page) =>
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)

const boxOf = (page: Page, selector: string) =>
  page.locator(selector).evaluate(element => {
    const {top, bottom, left, right, height} = element.getBoundingClientRect()
    return {top, bottom, left, right, height}
  })

test("the homepage reads without scripts: what a fleet is, then every fleet and its map", async ({browser}) => {
  const context = await browser.newContext({javaScriptEnabled: false})
  const page = await context.newPage()
  await page.goto("/")

  await expect(page.getByRole("heading", {name: "KeyFleet", level: 1})).toBeVisible()
  await expect(page.locator(".rl-hero-description")).toContainText("each hold a numbered key")
  await expect(page.getByRole("heading", {name: "The fleets", level: 2})).toBeVisible()

  const cards = page.locator(".rl-fleet-card")
  expect(await cards.evaluateAll(elements => elements.map(element => element.id))).toEqual(
    fleets.map(([id]) => `home-fleet-${id}`),
  )
  for (const [id, name, layout] of fleets) {
    const card = page.locator(`#home-fleet-${id}`)
    await expect(card.getByRole("heading", {level: 3})).toHaveText(name)
    await expect(card.locator("a.rl-fleet-card__link")).toHaveAttribute("href", `/app/fleets/${id}`)
    await expect(card.locator("a.rl-fleet-card__link")).not.toHaveAttribute("target", /.+/)
    await expect(card.locator(".key-map-preview")).toHaveAttribute("data-layout", layout)
    await expect(card.locator(".key-map-preview")).toHaveAttribute("aria-hidden", "true")
    await expect(card.locator("[data-fleet-progress]")).not.toBeEmpty()
  }

  await expect(page.locator("#home-fleet-fleet_tech_classic p").first()).toHaveText("144 keys, every one at 10 USDC.")
  await context.close()
})

test("each card draws its fleet's map, with the next key on sale marked", async ({page}) => {
  await page.goto("/")
  await waitForHomepage(page)
  await waitForPreviews(page)

  for (const [id] of fleets) {
    const preview = page.locator(`#home-fleet-preview-${id}`)
    await expect(preview.locator("svg")).toHaveCount(1)
    // No fleet in the test data has sold out, so each shows its next key on sale; the
    // map wraps around, so a young fleet's next key can show more than once.
    await expect(preview.locator('polygon[data-state="next"]').first()).toBeAttached()
  }

  // Only the fleets with levels colour their keys by level.
  await expect(page.locator("#home-fleet-preview-fibonacci_syndicate polygon[data-tone]").first()).toBeAttached()
  await expect(page.locator("#home-fleet-preview-fleet_tech_classic polygon[data-tone]")).toHaveCount(0)
})

test("Choose a fleet brings the fleets into view", async ({page}) => {
  await page.setViewportSize({width: 1440, height: 900})
  await page.goto("/")
  await waitForHomepage(page)

  await page.getByRole("link", {name: "Choose a fleet"}).click()
  await expect(page).toHaveURL(/#fleets$/)
  await expect
    .poll(() =>
      page.evaluate(() => {
        const section = document.querySelector("#fleets")!.getBoundingClientRect()
        return section.top < window.innerHeight && section.bottom > 0
      }),
    )
    .toBe(true)
})

test("a fleet's card opens that fleet's map", async ({page}) => {
  await page.goto("/")
  await waitForHomepage(page)

  await page.locator("#home-fleet-fleet_tech_classic a.rl-fleet-card__link").click()
  await expect(page).toHaveURL(/\/app\/fleets\/fleet_tech_classic$/)
  await expect(page.getByRole("heading", {level: 1, name: "Keyfleet Classic"})).toBeVisible()
})

test("the header reaches the account page", async ({page}) => {
  await page.goto("/")
  await waitForHomepage(page)

  await expect(page.locator(".rl-header").getByRole("link", {name: "Account"})).toHaveAttribute("href", "/account")
})

test("the homepage settles immediately for reduced motion", async ({browser}) => {
  const context = await browser.newContext({reducedMotion: "reduce"})
  const page = await context.newPage()
  await page.goto("/")
  await waitForHomepage(page)
  await expect(page.locator("[data-home-hero-copy]")).toBeVisible()
  await waitForPreviews(page)
  await context.close()
})

// Everything a landing render is allowed to differ by: the CSRF token and the
// LiveView handshake, all minted per request.
const stableRender = (html: string) =>
  html
    .replace(/csrf-token" content="[^"]*"/g, 'csrf-token" content="TOKEN"')
    .replace(/data-phx-session="[^"]*"/g, 'data-phx-session="SESSION"')
    .replace(/data-phx-static="[^"]*"/g, 'data-phx-static="STATIC"')
    .replace(/id="phx-[^"]*"/g, 'id="ID"')

// The landing is a dark-only composition: whatever palette the visitor saved, every render
// is the same dark page, and only the per-request tokens differ.
test("the public landing renders the same dark page for every saved palette", async ({browser}) => {
  const landing = async (saved?: "light" | "dark") => {
    const context = await browser.newContext()
    if (saved) {
      await context.addCookies([
        {name: "regent_theme", value: saved, url: test.info().project.use.baseURL as string},
      ])
    }
    const served = await (await context.request.get("/")).text()
    await context.close()
    return served
  }

  const [none, light, dark] = await Promise.all([landing(), landing("light"), landing("dark")])

  const main = (html: string) => stableRender(html).match(/<main>[\s\S]*?<\/main>/)?.[0]
  expect(main(light)).toBe(main(dark))
  expect(main(none)).toBe(main(dark))

  for (const served of [none, light, dark]) {
    expect(served).toContain('data-theme="dark"')
    expect(served).toContain('data-home-theme-locked="true"')
    expect(served).toContain('<meta name="color-scheme" content="dark"')
    expect(served).toContain('data-brand="platform"')
  }
})

// The lock is not a rewrite of the visitor's preference: a saved light theme still renders
// the dark landing, offers no switch, and leaves the saved choice for the other pages.
test("the landing stays dark and preserves the visitor's saved theme", async ({browser}) => {
  const context = await browser.newContext()
  await context.addCookies([
    {name: "regent_theme", value: "light", url: test.info().project.use.baseURL as string},
  ])
  const page = await context.newPage()

  await page.goto("/")
  await waitForHomepage(page)

  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark")
  await expect(page.locator("html")).toHaveAttribute("data-home-theme-locked", "true")
  await expect(page.locator("[data-theme-toggle]:visible")).toHaveCount(0)
  const saved = (await context.cookies()).find(cookie => cookie.name === "regent_theme")
  expect(saved?.value).toBe("light")
  await context.close()
})

test("the landing keeps its display face for headings", async ({page}) => {
  await page.goto("/")
  await waitForHomepage(page)

  expect(await page.locator("#home-title").evaluate(element => getComputedStyle(element).fontFamily)).toContain(
    "Geist Pixel Square",
  )
})

// The crown is decoration drawn inside the hero: hidden from assistive technology,
// taking no pointer events, and showing exactly one layer at a time — the still art
// until the drawn crown is ready, then the drawn crown alone. Whether headless Chromium
// brings a GPU decides which layer shows, never whether the words and links stay reachable.
test("the crown never blocks the hero's words or links", async ({page}) => {
  const expectOneHeroLayer = async () => {
    const layers = await page.locator("#home-prism").evaluate(element => ({
      art: getComputedStyle(element.querySelector(".rl-hero-art")!).visibility,
      crownReady: element.getAttribute("data-prism-ready") === "true",
    }))
    expect(layers.art).toBe(layers.crownReady ? "hidden" : "visible")
  }

  for (const viewport of [{width: 1280, height: 800}, {width: 390, height: 844}]) {
    await page.setViewportSize(viewport)
    await page.goto("/")
    const prism = page.locator("#home-prism")
    await expect(prism).toHaveAttribute("aria-hidden", "true")
    expect(await prism.evaluate(element => getComputedStyle(element).pointerEvents)).toBe("none")
    await expectOneHeroLayer()
    await expect(page.locator("#home-title")).toBeVisible()
    await page.getByRole("link", {name: "Choose a fleet"}).click({trial: true})
    await page.emulateMedia({reducedMotion: "reduce"})
    await expectOneHeroLayer()
    await page.emulateMedia({reducedMotion: "no-preference"})
  }
})

// The picture behind the hero is a grey line drawing with no ground of its own, so it takes
// whatever the page is painted. The file itself has to be that, with nothing on the page
// correcting it after the fact.
test("the picture behind the hero carries no colour and no ground of its own", async ({page}) => {
  await page.setViewportSize({width: 1440, height: 900})
  await page.goto("/")
  await waitForHomepage(page)

  const picture = await page.locator(".rl-hero-art").evaluate(element => {
    const image = element as HTMLImageElement
    const meanBrightnessOver = (ground: string | null) => {
      const canvas = document.createElement("canvas")
      canvas.width = image.naturalWidth
      canvas.height = image.naturalHeight
      const context = canvas.getContext("2d", {willReadFrequently: true})!
      if (ground) {
        context.fillStyle = ground
        context.fillRect(0, 0, canvas.width, canvas.height)
      }
      context.drawImage(image, 0, 0)
      const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data
      let total = 0
      let widestChannelSpread = 0
      for (let index = 0; index < pixels.length; index += 4) {
        const channels = [pixels[index], pixels[index + 1], pixels[index + 2]]
        total += (channels[0] + channels[1] + channels[2]) / 3
        if (pixels[index + 3] === 0) continue
        widestChannelSpread = Math.max(widestChannelSpread, Math.max(...channels) - Math.min(...channels))
      }
      return {mean: total / (pixels.length / 4), widestChannelSpread}
    }

    const onWhite = meanBrightnessOver("#ffffff")
    const onBlack = meanBrightnessOver("#000000")
    return {
      greyOnItsOwn: meanBrightnessOver(null).widestChannelSpread,
      greyOnWhite: onWhite.widestChannelSpread,
      groundShowsThrough: onWhite.mean - onBlack.mean,
      correction: getComputedStyle(image).filter,
    }
  })

  expect(picture.greyOnItsOwn, "every mark in the file is grey").toBe(0)
  expect(picture.greyOnWhite, "and stays grey over a light page").toBe(0)
  expect(picture.groundShowsThrough, "the page behind it fills the frame").toBeGreaterThan(200)
  expect(picture.correction, "with nothing on the page correcting it").toBe("none")
})

// Four across where there is room, fewer as the page narrows, one column on a phone;
// always in catalog order, inside the page, and big enough to press.
test("the fleet cards fit every viewport in catalog order", async ({page}) => {
  for (const viewport of viewports) {
    await test.step(viewport.name, async () => {
      await page.setViewportSize({width: viewport.width, height: viewport.height})
      await page.goto("/")
      await waitForHomepage(page)
      await assertNoOverflow(page)

      const boxes = await page.locator(".rl-fleet-card__link").evaluateAll(elements =>
        elements.map(element => {
          const {top, left, right, height} = element.getBoundingClientRect()
          return {top: Math.round(top), left: Math.round(left), right, height}
        }),
      )
      expect(boxes).toHaveLength(4)
      expect(boxes.every(box => box.height >= 44 && box.left >= 0 && box.right <= viewport.width)).toBe(true)

      // Reading order: left to right along a row, then down to the next row.
      for (const [index, box] of boxes.entries()) {
        if (index === 0) continue
        const before = boxes[index - 1]
        expect(box.top > before.top || (box.top === before.top && box.left > before.left)).toBe(true)
      }

      const rows = new Set(boxes.map(box => box.top)).size
      if (viewport.width >= 1440) expect(rows, "four across on a wide screen").toBe(1)
      if (viewport.width < 480) expect(rows, "one column on a phone").toBe(4)
    })
  }
})

test("on a phone the words come first, then the crown, then the fleets", async ({page}) => {
  for (const width of [390, 320]) {
    await test.step(`${width} wide`, async () => {
      await page.setViewportSize({width, height: 844})
      await page.goto("/")
      await waitForHomepage(page)
      await assertNoOverflow(page)

      const title = await boxOf(page, "#home-title")
      const intro = await boxOf(page, ".rl-hero-description")
      const crown = await boxOf(page, "#home-prism")
      const cards = await boxOf(page, "#fleets")

      expect(title.bottom).toBeLessThanOrEqual(intro.top)
      expect(intro.bottom).toBeLessThanOrEqual(crown.top)
      expect(crown.bottom).toBeLessThanOrEqual(cards.top)
    })
  }
})

// Every control on the page shows a solid ring of at least two pixels when the
// keyboard reaches it, and the keyboard reaches every fleet.
test("every control keeps a visible keyboard focus ring", async ({page}) => {
  await page.setViewportSize({width: 1440, height: 900})
  await page.goto("/")
  await waitForHomepage(page)

  const count = await page.locator("a, button").count()
  const reached = new Set<string>()
  for (let tab = 0; tab <= count; tab += 1) {
    await page.keyboard.press("Tab")
    const result = await page.evaluate(() => {
      const element = document.activeElement as HTMLElement
      if (!element?.closest(".rl-hero, .rl-fleets") || !element.matches(":focus-visible")) return null
      const style = getComputedStyle(element)
      return {
        name: element.querySelector("h3")?.textContent?.trim() ?? element.textContent?.trim() ?? "",
        width: parseFloat(style.outlineWidth),
        outline: style.outlineStyle,
        opacity: style.opacity,
      }
    })
    if (!result) continue
    reached.add(result.name)
    expect(result.width, result.name).toBeGreaterThanOrEqual(2)
    expect(result.outline, result.name).toBe("solid")
    expect(Number(result.opacity), result.name).toBeGreaterThan(0)
  }
  expect([...reached]).toEqual(["Choose a fleet", ...fleets.map(([, name]) => name)])
})

test("the homepage captures its phone, tablet and zoomed states", async ({browser}, testInfo) => {
  for (const capture of [
    {height: 720, name: "final-mobile-320-dark.png", width: 320},
    {height: 844, name: "final-mobile-390-dark.png", width: 390},
    {height: 1024, name: "final-tablet-768-dark.png", width: 768},
    {height: 900, name: "final-zoom-200-dark.png", width: 640},
  ]) {
    const context = await browser.newContext({colorScheme: "dark", viewport: {width: capture.width, height: capture.height}})
    const page = await context.newPage()
    await page.goto("/")
    await waitForHomepage(page)
    await waitForPreviews(page)
    await assertNoOverflow(page)
    await page.screenshot({path: testInfo.outputPath(capture.name), fullPage: true})
    await context.close()
  }
})
