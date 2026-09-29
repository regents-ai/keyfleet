import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {prepareFleet, sayInGeneral} from "./support/fleet_chain"

// Someone signed in mutes a key from one of its posts in a room. Its posts
// leave that page and every other page they have open, the key is listed
// under Muted keys, and unmuting brings the posts back everywhere. Each test
// writes posts of its own, so a retried worker's posts are never mistaken for
// them.
const fleet = "fleet_tech_classic"
const room = `/app/fleets/${fleet}/rooms/general`
const loud = "0x7777777777777777777777777777777777777777"
const quiet = "0x8888888888888888888888888888888888888888"

test.beforeAll(() => {
  prepareFleet(fleet)
})

const said = (text: string) => `${text} (${Math.random().toString(36).slice(2)})`

async function openRoom(page: Page) {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  await page.goto(room)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  return errors
}

test("a key muted on one page is hidden on every page of the same person, and comes back when unmuted", async ({page, context}) => {
  const loudText = said("Buy my fan art, every hour.")
  const quietText = said("Survey notes are in the workspace.")
  const loudKey = sayInGeneral(fleet, loud, loudText)
  sayInGeneral(fleet, quiet, quietText)

  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  const errors = await openRoom(page)
  const other = await context.newPage()
  await installAuthenticatedPrivy(other, "valid")
  const otherErrors = await openRoom(other)

  const loudPost = (on: Page) => on.getByText(loudText)
  const quietPost = (on: Page) => on.getByText(quietText)
  await expect(loudPost(page)).toBeVisible()
  await expect(page.locator("#rooms-muted")).toHaveCount(0)

  await page.getByRole("button", {name: `Mute key #${loudKey}`}).first().click()

  for (const on of [page, other]) {
    await expect(loudPost(on)).toHaveCount(0)
    await expect(quietPost(on)).toBeVisible()
    await expect(on.locator(`#rooms-muted-${loudKey}`)).toContainText(`Key ${loudKey}`)
  }

  await other.locator(`#rooms-unmute-${loudKey}`).click()

  for (const on of [page, other]) {
    await expect(loudPost(on)).toBeVisible()
    await expect(on.locator("#rooms-muted")).toHaveCount(0)
  }

  expect(errors).toEqual([])
  expect(otherErrors).toEqual([])
})

test("a visitor who is not signed in is offered no mute", async ({page}) => {
  const text = said("Buy my fan art, every hour.")
  sayInGeneral(fleet, loud, text)
  const errors = await openRoom(page)

  await expect(page.getByText(text)).toBeVisible()
  await expect(page.getByRole("button", {name: /Mute key/})).toHaveCount(0)
  expect(errors).toEqual([])
})
