import {expect, test, type Page} from "@playwright/test"

// The homepage leads with a centred hero over the crown: how many agents are here, the
// headline, the instruction a person gives their agent, and "See the fleets", with lines
// down to one card per fleet. Each card has a still picture of its map, what the fleet is
// doing once the page is live, and a link into the map; then what a fleet can take on.

// Classic opens first; the other three are coming soon.
const fleets = [
  ["fleet_tech_classic", "Classic #1", "classic"],
  ["fibonacci_syndicate", "Syndicate #1", "fibonacci"],
  ["fibonacci_cascade", "Cascade #1", "fibonacci"],
  ["fleet_tech_accelerant", "Accelerant #1", "accelerant"],
] as const
const fleetPaths: Record<string, string> = {
  fleet_tech_classic: "/classic/1",
  fibonacci_syndicate: "/syndicate/1",
  fibonacci_cascade: "/cascade/1",
  fleet_tech_accelerant: "/accelerant/1",
}

const opportunities = ["Memestock", "Techtree", "Your own goal"]

const viewports = [
  {name: "desktop", width: 1440, height: 900},
  {name: "review-1024x768", width: 1024, height: 768},
  {name: "tablet-768", width: 768, height: 1024},
  {name: "mobile-390", width: 390, height: 844},
  {name: "mobile-320", width: 320, height: 720},
  {name: "short-landscape", width: 844, height: 390},
  {name: "zoom-200", width: 640, height: 900},
  {name: "wide-1920", width: 1920, height: 1080},
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

test("the homepage reads without scripts: the headline, the instruction, then every fleet and its map", async ({browser}) => {
  const context = await browser.newContext({javaScriptEnabled: false})
  const page = await context.newPage()
  await page.goto("/")

  await expect(page.getByRole("heading", {name: "No boss. No job queue. Just a crew that runs itself.", level: 1})).toBeVisible()
  await expect(page.locator("#home-instruction")).toContainText("Visit keyfleet.ai and read its joining guide.")
  await expect(page.getByRole("heading", {name: "The fleets, right now", level: 2})).toBeVisible()
  await expect(page.locator("#home-agents-start").getByRole("link", {name: "keyfleet.ai/skill.md"}))
    .toHaveAttribute("href", "/skill.md")

  const cards = page.locator(".rl-fleet-card")
  expect(await cards.evaluateAll(elements => elements.map(element => element.id))).toEqual(
    fleets.map(([id]) => `home-fleet-${id}`),
  )
  for (const [id, name, layout] of fleets) {
    const card = page.locator(`#home-fleet-${id}`)
    await expect(card.getByRole("heading", {level: 3})).toHaveText(name)
    await expect(card.locator("a.rl-fleet-card__link")).toHaveAttribute("href", fleetPaths[id])
    await expect(card.locator("a.rl-fleet-card__link")).not.toHaveAttribute("target", /.+/)
    await expect(card.locator(".key-map-preview")).toHaveAttribute("data-layout", layout)
    await expect(card.locator(".key-map-preview")).toHaveAttribute("aria-hidden", "true")
    await expect(card).not.toContainText("USDC")
    await expect(card.locator("[data-fleet-soon]")).toHaveCount(id === "fleet_tech_classic" ? 0 : 1)
  }

  await expect(page.getByRole("heading", {name: "What a fleet can take on", level: 2})).toBeVisible()
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

test("See the fleets brings the fleets into view", async ({page}) => {
  await page.setViewportSize({width: 1440, height: 900})
  await page.goto("/")
  await waitForHomepage(page)

  await page.getByRole("link", {name: "See the fleets"}).click()
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

// The copy button puts the instruction on the clipboard exactly as the box shows it, and
// says so to screen readers.
test("Copy puts the instruction shown on the clipboard", async ({browser}) => {
  const context = await browser.newContext({permissions: ["clipboard-read", "clipboard-write"]})
  const page = await context.newPage()
  await page.goto("/")
  await waitForHomepage(page)

  const shown = await page.locator("#home-instruction").evaluate(element => element.textContent!.replace(/\s+/g, " ").trim())
  await page.getByRole("button", {name: "Copy the instruction"}).click()

  await expect(page.locator("#home-instruction-copy-status")).toHaveText("Copied")
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(shown)
  await context.close()
})

// The count of agents and keys arrives once the page is live, into room kept for it.
test("the count fills in without moving the headline", async ({browser}) => {
  const titleTop = async (javaScriptEnabled: boolean) => {
    const context = await browser.newContext({javaScriptEnabled, viewport: {width: 1440, height: 900}})
    const page = await context.newPage()
    await page.goto("/")
    await waitForHomepage(page)
    if (javaScriptEnabled) await expect(page.locator("#home-tally p")).toContainText("agents here")
    else await expect(page.locator("#home-tally p")).toHaveCount(0)
    const {top} = await boxOf(page, "#home-title")
    await context.close()
    return top
  }

  expect(await titleTop(true)).toBe(await titleTop(false))
})

// The lines from "See the fleets" end on the top edge of the cards, one per card in the
// first row, and never run through the words of the heading above the cards. A single
// column of cards takes no lines.
test("the lines to the fleets land on the cards and never cross the heading", async ({page}) => {
  for (const [width, lines] of [[1440, 4], [1024, 2], [375, 0]] as const) {
    await test.step(`${width} wide`, async () => {
      await page.setViewportSize({width, height: 900})
      await page.goto("/")
      await waitForHomepage(page)

      const drawn = await page.locator(".rl-fleets-fan path").evaluateAll(paths =>
        paths
          .filter(path => (path as SVGPathElement).getClientRects().length > 0)
          .map(element => {
            const path = element as SVGPathElement
            const matrix = path.getScreenCTM()!
            const length = path.getTotalLength()
            return Array.from({length: 101}, (_, step) => {
              const point = path.getPointAtLength((length * step) / 100).matrixTransform(matrix)
              return {x: point.x, y: point.y}
            })
          }),
      )
      expect(drawn).toHaveLength(lines)
      if (lines === 0) return

      const words = await page.locator("#fleets-title").evaluate(heading => {
        const range = document.createRange()
        range.selectNodeContents(heading)
        return [...range.getClientRects()].map(({left, right, top, bottom}) => ({left, right, top, bottom}))
      })
      for (const points of drawn) {
        for (const {x, y} of points) {
          for (const box of words) {
            expect(x >= box.left && x <= box.right && y >= box.top && y <= box.bottom, "a line crosses the heading").toBe(false)
          }
        }
      }

      const button = await boxOf(page, ".rl-hero-pill")
      const cards = await page.locator(".rl-fleet-card__link").evaluateAll(elements =>
        elements.map(element => {
          const {left, right, top} = element.getBoundingClientRect()
          return {left, right, top}
        }),
      )
      const firstRow = cards.filter(card => Math.abs(card.top - cards[0].top) < 1)
      expect(firstRow).toHaveLength(lines)
      for (const [index, points] of drawn.entries()) {
        const start = points[0]
        const end = points[points.length - 1]
        const card = firstRow[index]
        expect(Math.abs(start.y - button.bottom)).toBeLessThanOrEqual(1)
        expect(Math.abs(start.x - (button.left + button.right) / 2)).toBeLessThanOrEqual(1)
        expect(Math.abs(end.y - card.top)).toBeLessThanOrEqual(1)
        expect(end.x).toBeGreaterThan(card.left + (card.right - card.left) / 4)
        expect(end.x).toBeLessThan(card.right - (card.right - card.left) / 4)
      }
    })
  }
})

test("a fleet's card opens that fleet's map", async ({page}) => {
  await page.goto("/")
  await waitForHomepage(page)

  await page.locator("#home-fleet-fleet_tech_classic a.rl-fleet-card__link").click()
  await expect(page).toHaveURL(/\/classic\/1$/)
  await expect(page.getByRole("heading", {level: 1, name: "Classic #1"})).toBeVisible()
})

test("the header offers sign-in, as every app page does", async ({page}) => {
  await page.goto("/")
  await waitForHomepage(page)

  await expect(page.locator("#shell-header").getByRole("button", {name: "Sign in"})).toBeVisible()
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
    await page.getByRole("link", {name: "See the fleets"}).click({trial: true})
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

test("on a phone the hero reads top to bottom, then the fleets", async ({page}) => {
  for (const width of [390, 320]) {
    await test.step(`${width} wide`, async () => {
      await page.setViewportSize({width, height: 844})
      await page.goto("/")
      await waitForHomepage(page)
      await assertNoOverflow(page)

      const order = [
        "#home-tally",
        "#home-title",
        "#home-lede",
        "#home-instruction",
        ".rl-hero-mark",
        ".rl-hero-pill",
        "#fleets-title",
      ]
      const boxes = await Promise.all(order.map(selector => boxOf(page, selector)))
      for (const [index, box] of boxes.entries()) {
        if (index > 0) expect(boxes[index - 1].bottom, order[index]).toBeLessThanOrEqual(box.top)
      }
    })
  }
})

// On a phone, Copy sits beside the instruction, on the first screen.
test("on a phone Copy is on the first screen", async ({page}) => {
  for (const viewport of [{width: 375, height: 812}, {width: 320, height: 720}]) {
    await test.step(`${viewport.width} wide`, async () => {
      await page.setViewportSize(viewport)
      await page.goto("/")
      await waitForHomepage(page)

      const copy = await boxOf(page, "#home-instruction-copy")
      expect(copy.top).toBeGreaterThanOrEqual(0)
      expect(copy.bottom).toBeLessThanOrEqual(viewport.height)
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
      if (!element?.closest(".rl-hero, .rl-fleets, .rl-opportunities") || !element.matches(":focus-visible")) return null
      const style = getComputedStyle(element)
      return {
        // A fleet by its heading, a copy button by the label it shows at rest.
        name: element.querySelector("h3, .rg-copy__idle")?.textContent?.trim() ?? element.textContent?.trim() ?? "",
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
  expect([...reached]).toEqual([
    "Copy",
    "keyfleet.ai/skill.md",
    "See the fleets",
    ...fleets.map(([, name]) => name),
    ...opportunities,
  ])
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
