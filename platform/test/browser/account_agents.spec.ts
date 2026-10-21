import {expect, test, type Page} from "@playwright/test"
import {newAgent, pairPerson} from "./support/agent_tools"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"

// A person manages their paired agents on the Account page, as on regents.sh:
// See what it has done opens the agent's window, Done closes it, and Unpair,
// once confirmed, takes the agent off the account. The window is the shared
// cut-corner dialog, on a wide screen and on a phone.
const person = "did:privy:verified"

async function signIn(page: Page) {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  return errors
}

async function openAccount(page: Page) {
  await page.goto("/account")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
}

for (const viewport of [{width: 1280, height: 800}, {width: 390, height: 844}]) {
  test(`at ${viewport.width} px, an agent's window opens and closes, and Unpair takes the agent off the account`, async ({page}) => {
    await page.setViewportSize(viewport)
    const name = `Astra ${viewport.width}`
    pairPerson(newAgent(), person, name)
    const errors = await signIn(page)
    await openAccount(page)

    const row = page.locator("#account-agents li", {hasText: name})
    const dialog = page.locator("#account-agent-dialog")
    await row.getByRole("button", {name: `See what ${name} has done`}).click()
    await expect(dialog).toBeVisible()
    await expect(dialog.getByRole("heading", {name})).toBeVisible()
    await expect(dialog).toContainText("spent for you on Regent sites.")
    const box = (await dialog.boundingBox())!
    expect(box.x).toBeGreaterThanOrEqual(0)
    expect(box.x + box.width).toBeLessThanOrEqual(viewport.width)

    await dialog.getByRole("button", {name: "Done"}).click()
    await expect(dialog).toBeHidden()

    await row.getByRole("button", {name: `See what ${name} has done`}).click()
    await expect(dialog).toBeVisible()
    page.once("dialog", confirm => confirm.accept())
    await dialog.getByRole("button", {name: "Unpair"}).click()

    await expect(dialog).toBeHidden()
    await expect(row).toHaveCount(0)
    await expect(page.locator("#account-agents [role=status]")).toHaveText(
      `${name} is unpaired. It will need a new code to pair again.`,
    )
    expect(errors).toEqual([])
  })
}

test("on a 320 px phone, each account tab is a whole thumb wide and the four fit without scrolling", async ({page}) => {
  await page.setViewportSize({width: 320, height: 700})
  await signIn(page)
  await openAccount(page)

  const tabs = page.locator("#shell-tabs a")
  await expect(tabs).toHaveCount(4)
  for (const tab of await tabs.all()) {
    const box = (await tab.boundingBox())!
    expect.soft(box.width, await tab.innerText()).toBeGreaterThanOrEqual(44)
    expect.soft(box.height, await tab.innerText()).toBeGreaterThanOrEqual(44)
  }
  expect(await page.locator("#shell-tabs").evaluate(strip => strip.scrollWidth <= strip.clientWidth)).toBe(true)
})
