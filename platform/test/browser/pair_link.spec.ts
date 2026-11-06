import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"

// A "Bring your agent" link (/pair?to=<page>): the person pairs their agent there,
// and the message they paste ends by sending the agent to that page once it is paired. A
// link to anywhere but a page on this site opens plain pairing.

const box = (page: Page) => page.locator("#pair-pairing-box")
const message = (page: Page) => box(page).locator("pre")

async function open(page: Page, path: string) {
  await page.goto(path)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
}

// The page opens on the list of agents; a choice closes it, so a later one opens it again.
async function choose(page: Page, agent: string) {
  const radio = box(page).getByRole("radio", {name: agent, exact: true})
  const list = box(page).locator("details")
  if (!(await list.evaluate(details => (details as HTMLDetailsElement).open))) await list.locator("summary").click()
  await radio.locator("xpath=ancestor::label").click()
  await expect(radio).toBeChecked()
}

test.describe("signed in", () => {
  test.beforeEach(async ({page}) => {
    await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  })

  test("the message sends the agent to the link's page once paired", async ({page}) => {
    const errors: string[] = []
    page.on("pageerror", error => errors.push(error.message))
    await open(page, "/pair?to=%2Fclassic%2F1")
    const start = page.locator("#pair-start a")
    await expect(start).toHaveText(/^https?:\/\/[^/]+\/classic\/1$/)

    await choose(page, "Dots")
    await expect(message(page)).toContainText(/Pairing code:\s*\S{12,}/)
    const last = `\nOnce paired, start at ${await start.innerText()}`
    expect((await message(page).innerText()).trimEnd().endsWith(last)).toBe(true)
    expect(errors).toEqual([])
  })

  test("on a 320 px phone the pairing box and the start link stay on screen", async ({page}) => {
    await page.setViewportSize({width: 320, height: 700})
    await open(page, "/pair?to=%2Fclassic%2F1%2Fworkspace%3Fproject%3Dunderstanding%26place%3Ddocs")
    await choose(page, "Dots")
    await expect(message(page)).toContainText(/Pairing code:\s*\S{12,}/)
    for (const part of [box(page), page.locator("#pair-start")]) {
      const {x, width} = (await part.boundingBox())!
      expect(x).toBeGreaterThanOrEqual(0)
      expect(x + width).toBeLessThanOrEqual(320)
    }
  })

  test("a link to another site opens plain pairing", async ({page}) => {
    await open(page, "/pair?to=%2F%2Fexample.com")
    await expect(page.locator("#pair-start")).toHaveCount(0)

    await choose(page, "Dots")
    await expect(message(page)).toContainText(/Pairing code:\s*\S{12,}/)
    await expect(message(page)).not.toContainText("Once paired")
  })
})

test("a visitor signs in first, and still sees where their agent will start", async ({page}) => {
  await open(page, "/pair?to=%2Fclassic%2F1")
  await expect(page.locator("#pair-signed-out").getByRole("button", {name: "Sign in"})).toBeVisible()
  await expect(page.locator("#pair-start a")).toHaveText(/\/classic\/1$/)
  await expect(box(page)).toHaveCount(0)
})
