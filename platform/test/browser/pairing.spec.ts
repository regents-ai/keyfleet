import {expect, test, type Locator, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"

// The pairing window that Pair New Agent opens on the Agents page: the chosen
// agent's picture sits in a low band, and the list of agents drops in and
// leaves with a short move from the motion kit that never holds back a press.
// Opening, Escape and the window's one height are walked in account_menu.spec.ts.

const pairingWindow = (page: Page) => page.locator("#shell-pairing")
const box = (page: Page) => page.locator("form#shell-pairing-box")
const message = (page: Page) => box(page).locator("pre")
const dropdown = (page: Page) => box(page).locator("details")
const agents = (page: Page) => dropdown(page).locator("[data-panel='list']")
const picture = (page: Page) => box(page).locator(".rg-account__stage")
const steps = (page: Page) => box(page).locator("ol")

const top = (locator: Locator) => locator.evaluate(element => element.getBoundingClientRect().top)
const opacity = (locator: Locator) => locator.evaluate(element => Number(getComputedStyle(element).opacity))

async function signIn(page: Page) {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  return errors
}

async function openWindow(page: Page) {
  await page.goto("/account/agents")
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
  await page.locator("#account-agents").getByRole("button", {name: "Pair New Agent"}).click()
  await expect(pairingWindow(page)).toBeVisible()
  // The motion kit hands each part back to its stylesheet once it rests.
  await expect(pairingWindow(page)).not.toHaveAttribute("style")
  await expect(agents(page)).not.toHaveAttribute("style")
}

// The dropdown opens when it is closed; the agent's label carries the press.
async function choose(page: Page, agent: string) {
  const radio = box(page).getByRole("radio", {name: agent, exact: true, includeHidden: true})
  if (!(await dropdown(page).evaluate(details => (details as HTMLDetailsElement).open)))
    await dropdown(page).locator("summary").click()
  await radio.locator("xpath=ancestor::label").click()
  await expect(radio).toBeChecked()
}

// The page's clock, held still so a move in the list can be pressed half way.
async function holdClock(page: Page) {
  await page.clock.pauseAt(await page.evaluate(() => Date.now() + 1000))
}

for (const width of [1280, 390, 320]) {
  // Sean, 11 Nov 2026: "the image area can be much smaller". The picture sits in
  // a band at most half the height of the old 16:9 box, sharp and centred, and
  // choosing another agent moves nothing under it.
  test(`at ${width} px the agent's picture sits in a low band, and choosing moves nothing under it`, async ({page}) => {
    await page.setViewportSize({width, height: 844})
    const errors = await signIn(page)
    await openWindow(page)

    await choose(page, "Dots")
    await expect(message(page)).toContainText(/Pairing code/)
    const band = await picture(page).evaluate(stage => {
      const outer = stage.getBoundingClientRect()
      const image = stage.querySelector("img")!
      const inner = image.getBoundingClientRect()
      return {
        width: outer.width,
        height: outer.height,
        offCentre: Math.max(
          Math.abs(inner.left + inner.width / 2 - (outer.left + outer.width / 2)),
          Math.abs(inner.top + inner.height / 2 - (outer.top + outer.height / 2)),
        ),
        inside: inner.top >= outer.top && inner.bottom <= outer.bottom,
        sharp: image.naturalWidth >= inner.width * devicePixelRatio,
      }
    })
    expect(band.height).toBeLessThanOrEqual((band.width * 9) / 16 / 2)
    expect(band).toMatchObject({inside: true, sharp: true})
    expect(band.offCentre).toBeLessThan(1)
    // The list is closed now; this is where the steps rest.
    await expect(agents(page)).toBeHidden()
    const resting = await top(steps(page))

    await choose(page, "Hermes")
    await expect(message(page)).toContainText(/Pairing code/)
    expect(await picture(page).evaluate(stage => stage.getBoundingClientRect().height)).toBe(band.height)
    await expect(agents(page)).toBeHidden()
    expect(await top(steps(page))).toBe(resting)

    const drawn = (await pairingWindow(page).boundingBox())!
    expect(drawn.x).toBeGreaterThanOrEqual(0)
    expect(drawn.x + drawn.width).toBeLessThanOrEqual(width)
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
    expect(errors).toEqual([])
  })
}

// The list drops in and leaves with a short move, and a press during it always
// counts: on an agent as it comes in, and on what is under the list as it leaves.
// The page's clock is held, so the press lands half way through each move.
test("a press during the list's move always counts", async ({page}) => {
  const errors = await signIn(page)
  await page.clock.install()
  await openWindow(page)
  await choose(page, "Dots")
  await expect(message(page)).toContainText(/Pairing code/)
  const first = await message(page).innerText()

  // Held 30 ms into the entrance, an agent still on its way in takes the press.
  await holdClock(page)
  await dropdown(page).locator("summary").click()
  await page.clock.runFor(30)
  const hermes = box(page).locator("label", {hasText: "Hermes"})
  expect(await opacity(hermes)).toBeLessThan(1)
  await hermes.click({force: true})
  await expect(box(page).getByRole("radio", {name: "Hermes", includeHidden: true})).toBeChecked()
  await expect(message(page)).not.toHaveText(first)
  const second = await message(page).innerText()

  // Held 30 ms into its exit, the list still covers the new-code button, which
  // takes the press.
  await expect(agents(page)).toHaveAttribute("data-leaving", "")
  await page.clock.runFor(30)
  await expect(agents(page)).toBeVisible()
  expect(await opacity(agents(page))).toBeLessThan(1)
  await box(page).getByRole("button", {name: "Make a new code"}).click()
  await expect(message(page)).not.toHaveText(second)
  await expect(message(page)).toContainText(/Pairing code:\s*\S{12,}/)

  // Each move ends within 200 ms and leaves nothing behind.
  await page.clock.runFor(170)
  await expect(agents(page)).not.toHaveAttribute("data-leaving")
  await expect(agents(page)).toBeHidden()
  await dropdown(page).locator("summary").click()
  await page.clock.runFor(200)
  await expect(dropdown(page)).toHaveAttribute("open", "")
  await expect(agents(page)).not.toHaveAttribute("style")
  expect(errors).toEqual([])
})

// With reduced motion asked for, the list opens and closes at once.
test("with reduced motion the list opens and closes at once", async ({page}) => {
  const errors = await signIn(page)
  await page.emulateMedia({reducedMotion: "reduce"})
  await page.clock.install()
  await openWindow(page)
  await choose(page, "Dots")
  await expect(message(page)).toContainText(/Pairing code/)

  await holdClock(page)
  await dropdown(page).locator("summary").click()
  await expect(dropdown(page)).toHaveAttribute("open", "")
  await expect(box(page).locator("label", {hasText: "Hermes"})).toHaveCSS("opacity", "1")
  await box(page).locator("label", {hasText: "Hermes"}).click()
  await expect(dropdown(page)).not.toHaveAttribute("open", "")
  await expect(agents(page)).not.toHaveAttribute("data-leaving")
  await expect(agents(page)).toBeHidden()
  expect(errors).toEqual([])
})
