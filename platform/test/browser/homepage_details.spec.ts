import {devices, expect, test, type Locator, type Page} from "@playwright/test"

// The homepage's hero, its Key card decks and the links around it, on a desktop and
// on a touch phone 390 wide (Playwright's Pixel 7 at that width). homepage.spec.ts
// reads the page itself.

const tagline = "A persistent team for your AI agent."

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

  // A finger gets the pass as it is: tapping the card shows no shuffle and loads none.
  // A finger opens the price's "i" with a tap; there is no hover to open it.
  test("a tap opens the price's info tip", async ({page}) => {
    await page.goto("/")
    await live(page)
    const words = page.locator("#home-price-tip")
    await page.getByRole("button", {name: "About the price"}).tap()
    await expect(words).toBeVisible()
  })

  test("tapping the next Key's card leaves it the pass", async ({page}) => {
    await page.goto("/")
    await live(page)
    await page.locator("#home-buy-card").tap()
    await page.waitForTimeout(800)
    await expect(page.locator("#home-buy-shuffle")).not.toHaveAttribute("src")
    expect(await page.locator("#home-buy-shuffle").evaluate(img => getComputedStyle(img).visibility)).toBe("hidden")
  })
})

// Less motion: the card stays the pass, with no dust and no shuffle.
test.describe("with less motion", () => {
  test.use({contextOptions: {reducedMotion: "reduce"}})

  test("the card stays still: no dust and no shuffle", async ({page}) => {
    await page.setViewportSize({width: 1280, height: 900})
    await page.goto("/")
    await live(page)
    const card = (await page.locator("#home-buy-card").boundingBox())!
    await page.mouse.move(card.x + card.width + 30, card.y + card.height / 2, {steps: 6})
    await page.locator("#home-buy-card").hover()
    await page.waitForTimeout(800)
    await expect(page.locator("#home-buy-shuffle")).not.toHaveAttribute("src")
    expect(await page.locator("#home-buy-shuffle").evaluate(img => getComputedStyle(img).visibility)).toBe("hidden")
    expect(await page.locator("#home-buy-dust").evaluate((canvas: HTMLCanvasElement) => canvas.width)).toBe(300)
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
  // The price's "i" opens while a mouse rests on it and closes once the mouse
  // leaves; a click keeps it open (the shared tip script, loaded in app.ts).
  test("the price's info tip opens under a mouse and a click keeps it", async ({page}) => {
    await page.goto("/")
    await live(page)
    const button = page.getByRole("button", {name: "About the price"})
    const words = page.locator("#home-price-tip")
    await button.hover()
    await expect(words).toBeVisible()
    await page.mouse.move(0, 0)
    await expect(words).toBeHidden()
    await button.hover()
    await button.click()
    await page.mouse.move(0, 0)
    await page.waitForTimeout(300)
    await expect(words).toBeVisible()
  })

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

  // Sean, 19 Oct: dust just outside the card's edge on the side facing the mouse,
  // following it and brighter the nearer it is. Read from the dust's own pixels,
  // left and right of the card.
  test("dust gathers outside the card on the side facing a mouse, brighter as it nears", async ({page}) => {
    await page.setViewportSize({width: 1280, height: 900})
    await page.goto("/")
    await live(page)
    const card = (await page.locator("#home-buy-card").boundingBox())!
    const middle = card.y + card.height / 2
    const lit = () =>
      page.locator("#home-buy-dust").evaluate((canvas: HTMLCanvasElement) => {
        const {data} = canvas.getContext("2d")!.getImageData(0, 0, canvas.width, canvas.height)
        const sides = [0, 0]
        for (let i = 3; i < data.length; i += 4) sides[(i >> 2) % canvas.width < canvas.width / 2 ? 0 : 1] += data[i]
        return {left: sides[0], right: sides[1]}
      })

    // The card sits right of centre, so the room to back away is on its left.
    await page.mouse.move(card.x - 300, middle, {steps: 6})
    await expect.poll(async () => (await lit()).left).toBeGreaterThan(0)
    await page.waitForTimeout(600)
    const far = await lit()
    await page.mouse.move(card.x - 30, middle, {steps: 6})
    await expect.poll(async () => (await lit()).left).toBeGreaterThan(far.left * 1.5)
    const near = await lit()
    expect(near.right, "the side away from the mouse").toBeLessThan(near.left * 0.1)

    await page.mouse.move(4, 4, {steps: 6})
    await expect.poll(async () => (await lit()).left).toBe(0)
  })

  // Pointing at the card or its button flashes the card and shows the shuffle,
  // the pass fading out under it; leaving both dissolves the two back over
  // about half a second.
  for (const [what, target] of [
    ["the card", "#home-buy-card"],
    ["the button", "#home-buy-next-key"],
  ]) {
    test(`pointing at ${what} flashes the card into the shuffle, and leaving dissolves it back`, async ({page}) => {
      await page.setViewportSize({width: 1280, height: 900})
      await page.goto("/")
      await live(page)
      const shuffle = page.locator("#home-buy-shuffle")
      const seen = (property: "opacity" | "visibility") => shuffle.evaluate((img, name) => getComputedStyle(img)[name], property)
      const pass = () => page.locator("#home-buy-pass").evaluate(img => getComputedStyle(img).opacity)
      await page.locator("#home-buy-tilt").evaluate(tilt => {
        const flashes: string[] = []
        new MutationObserver(() => flashes.push(tilt.style.filter)).observe(tilt, {attributeFilter: ["style"]})
        Object.assign(window, {flashes})
      })

      await page.locator(target).hover()
      await expect(shuffle).toHaveAttribute("src", /next-key-shuffle/)
      await expect.poll(() => seen("opacity")).toBe("1")
      await expect.poll(pass).toBe("0")
      expect(await page.evaluate(() => (window as unknown as {flashes: string[]}).flashes.some(f => f.includes("brightness")))).toBe(true)
      await expect.poll(() => page.locator("#home-buy-tilt").evaluate(tilt => tilt.style.filter)).toBe("")

      const left = await page.evaluate(() => performance.now())
      await page.mouse.move(4, 4, {steps: 2})
      await expect.poll(() => seen("visibility")).toBe("hidden")
      const gone = await page.evaluate(() => performance.now())
      expect(await seen("opacity")).toBe("0")
      expect(await pass()).toBe("1")
      expect(gone - left, "the dissolve takes about half a second").toBeGreaterThanOrEqual(450)
    })
  }

  // Sean, 19 Oct: a hundred cards over ten seconds, on a loop.
  test("the shuffle is a hundred cards at ten a second, looping", async ({page}) => {
    const picture = await (await page.request.get("/images/home/next-key-shuffle.webp")).body()
    expect(picture.toString("ascii", 0, 4) + picture.toString("ascii", 8, 12)).toBe("RIFFWEBP")
    const shows: number[] = []
    let loops = -1
    for (let at = 12; at < picture.length; ) {
      const chunk = picture.toString("ascii", at, at + 4)
      const size = picture.readUInt32LE(at + 4)
      if (chunk === "ANIM") loops = picture.readUInt16LE(at + 12)
      if (chunk === "ANMF") shows.push(picture.readUIntLE(at + 20, 3))
      at += 8 + size + (size % 2)
    }
    expect(loops, "loops forever").toBe(0)
    expect(shows).toEqual(Array(100).fill(100))
  })

  // Classic's deck turns only while it is on screen.
  test("Classic's deck of Key cards turns only while on screen", async ({page}) => {
    await page.setViewportSize({width: 1280, height: 700})
    await page.goto("/")
    await live(page)
    const deck = page.locator("#home-classic-cards")
    await expect(deck).not.toHaveAttribute("data-cards-turning")
    await deck.scrollIntoViewIfNeeded()
    await expect(deck).toHaveAttribute("data-cards-turning")
    await page.evaluate(() => window.scrollTo(0, 0))
    await expect(deck).not.toHaveAttribute("data-cards-turning")
  })
})
