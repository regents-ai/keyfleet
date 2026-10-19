import {devices, expect, test, type Locator, type Page} from "@playwright/test"

// The homepage's hero, its Key card decks and the links around it, on a desktop and
// on a touch phone 390 wide (Playwright's Pixel 7 at that width). homepage.spec.ts
// reads the page itself.

const tagline = "Your personal agent joins a Fleet with a Key."

const phone = {
  userAgent: devices["Pixel 7"].userAgent,
  deviceScaleFactor: devices["Pixel 7"].deviceScaleFactor,
  isMobile: true,
  hasTouch: true,
  viewport: {width: 390, height: 844},
}

// The page is live: its scripts are wired and its hooks mounted.
const live = (page: Page) => expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()

// Each link and button a person can see in `area` is named and at least 44 pixels
// square. Boxes come back a few millionths of a pixel short, so they are rounded.
async function eachFitsAThumb(area: Locator) {
  const targets = area.getByRole("link").or(area.getByRole("button"))
  let seen = 0
  for (const target of await targets.all()) {
    if (!(await target.isVisible())) continue
    seen += 1
    const box = (await target.boundingBox())!
    const name = (await target.getAttribute("aria-label")) ?? (await target.innerText())
    await expect.soft(target, `${await target.evaluate(element => element.outerHTML.slice(0, 80))} named`).toHaveAccessibleName(/\S/)
    expect.soft(Math.round(box.width), `${name} wide`).toBeGreaterThanOrEqual(44)
    expect.soft(Math.round(box.height), `${name} tall`).toBeGreaterThanOrEqual(44)
  }
  expect(seen, "links and buttons seen").toBeGreaterThan(0)
}

test.describe("on a touch phone", () => {
  test.use(phone)

  test("every link and button in the header and footer is named and fits a thumb", async ({page}) => {
    await page.goto("/")
    await live(page)
    await eachFitsAThumb(page.getByRole("banner"))
    await eachFitsAThumb(page.getByRole("contentinfo"))
  })

  // Sean, 18 Oct: on phones and tablets the hex field stays its still drawing.
  test("the hex field stays its still drawing under a finger", async ({page}) => {
    await page.goto("/")
    await live(page)
    const hero = page.getByRole("region", {name: tagline})
    const box = (await hero.boundingBox())!
    await page.touchscreen.tap(box.x + box.width / 2, box.y + box.height / 2)
    await page.waitForTimeout(1_000)
    await expect(page.locator("#home-hero-field")).not.toHaveAttribute("data-field-ready")
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
  })
})

// From 768 wide the header shows the X and GitHub links too.
test.describe("on a touch tablet", () => {
  test.use({...phone, viewport: {width: 768, height: 1024}})

  test("every link and button in the header is named and fits a thumb", async ({page}) => {
    await page.goto("/")
    await live(page)
    await eachFitsAThumb(page.getByRole("banner"))
  })
})

test.describe("on a desktop", () => {
  // Under a mouse the links keep the design system's own sizes: the X and GitHub
  // marks are 24 pixels square.
  test("under a mouse the X and GitHub marks keep their own size", async ({page}) => {
    await page.setViewportSize({width: 1280, height: 900})
    await page.goto("/")
    for (const area of [page.getByRole("banner"), page.getByRole("contentinfo")]) {
      for (const name of ["Regents on X", "Regents on GitHub"]) {
        const box = (await area.getByRole("link", {name}).boundingBox())!
        expect([Math.round(box.width), Math.round(box.height)], name).toEqual([24, 24])
      }
    }
  })

  // The headline takes the hero's left half and the next Key sits in the middle of
  // its right half (as the template's Keyfleet hero does since 16 Oct).
  test("the next Key sits in the middle of the hero's right half", async ({page}) => {
    for (const width of [1024, 1280, 1440]) {
      await page.setViewportSize({width, height: 900})
      await page.goto("/")
      const hero = (await page.getByRole("region", {name: tagline}).boundingBox())!
      const headline = (await page.getByRole("heading", {name: tagline, level: 1}).boundingBox())!
      const buy = (await page.getByRole("button", {name: /Buy Next Key/}).boundingBox())!
      const rightHalf = hero.x + hero.width * 0.75
      expect(Math.abs(buy.x + buy.width / 2 - rightHalf), `${width} wide`).toBeLessThan(hero.width * 0.03)
      expect(headline.x + headline.width, `${width} wide`).toBeLessThanOrEqual(buy.x)
    }
  })

  // Under a mouse the card turns toward the pointer; once it has settled level it
  // keeps no turn of its own, so the stylesheet has it again.
  test("the next Key's card turns toward a mouse and keeps no turn once level", async ({page}) => {
    await page.setViewportSize({width: 1280, height: 900})
    await page.goto("/")
    await live(page)
    const tilt = page.locator("#home-buy-tilt")
    const card = (await tilt.boundingBox())!
    await page.mouse.move(card.x + card.width * 0.8, card.y + card.height * 0.2, {steps: 6})
    await expect.poll(() => tilt.evaluate(element => element.style.transform)).toContain("rotate")

    await page.mouse.move(4, 4, {steps: 6})
    await expect.poll(() => tilt.evaluate(element => element.style.transform)).toBe("")
  })

  // The decks beside each fleet's buttons turn only while they are on screen.
  test("each deck of Key cards turns only while on screen", async ({page}) => {
    await page.setViewportSize({width: 1280, height: 700})
    await page.goto("/")
    await live(page)
    for (const id of ["#home-classic-cards", "#home-club-cards"]) {
      const deck = page.locator(id)
      await page.evaluate(() => window.scrollTo(0, 0))
      await expect(deck).not.toHaveAttribute("data-cards-turning")
      await deck.scrollIntoViewIfNeeded()
      await expect(deck).toHaveAttribute("data-cards-turning")
      await page.evaluate(() => window.scrollTo(0, 0))
      await expect(deck).not.toHaveAttribute("data-cards-turning")
    }
  })
})
