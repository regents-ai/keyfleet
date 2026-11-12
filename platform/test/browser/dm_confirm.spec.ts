import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {prepareFleet, sellKey} from "./support/fleet_chain"

// In a direct message, Block and Delete conversation ask first in the shared
// confirm window: Cancel or Escape leave everything as it was, and the
// going-ahead button acts once. The window fits a phone and a wide screen.
const fleet = "fleet_tech_classic"
const me = "0x1111111111111111111111111111111111111111"
const stranger = "0x9999999999999999999999999999999999999999"

let mine = 0
let theirs = 0

test.beforeAll(() => {
  prepareFleet(fleet)
  mine = sellKey(fleet, me)
  theirs = sellKey(fleet, stranger)
})

async function openConversation(page: Page) {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  await page.goto(`/classic/1/keys/${mine}/dms/${theirs}`)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  await expect(page.locator("#dms-composer")).toBeVisible()
  return errors
}

for (const width of [1280, 390, 320]) {
  test(`at ${width} px, Block and Delete conversation ask first, then act once`, async ({page}) => {
    await page.setViewportSize({width, height: 844})
    const errors = await openConversation(page)
    const confirm = page.locator("#rg-confirm")
    const fits = async () => {
      const frame = (await confirm.boundingBox())!
      expect(frame.x).toBeGreaterThanOrEqual(0)
      expect(frame.x + frame.width).toBeLessThanOrEqual(width)
    }

    // Delete needs a conversation, so one message is sent first.
    await page.locator("#dms-composer textarea").fill(`Hello at ${width}`)
    await page.locator("#dms-composer").getByRole("button", {name: "Send"}).click()
    await expect(page.locator("#dms-thread-list")).toContainText(`Hello at ${width}`)

    const block = page.locator("#dms-block")
    await block.click()
    await expect(confirm).toBeVisible()
    await expect(confirm).toHaveAccessibleName(/^Block Key \d+\? Its messages still arrive, under Blocked/)
    await expect(confirm.getByRole("button", {name: "Cancel"})).toBeFocused()
    await fits()
    await page.keyboard.press("Escape")
    await expect(confirm).toBeHidden()
    await expect(block).toBeFocused()
    await expect(page.locator("#dms-blocked-note")).toHaveCount(0)

    await block.click()
    await confirm.getByRole("button", {name: "Block"}).click()
    await expect(confirm).toBeHidden()
    await expect(page.locator("#dms-blocked-note")).toHaveText("Blocked")
    await page.locator("#dms-unblock").click()
    await expect(page.locator("#dms-blocked-note")).toHaveCount(0)

    const remove = page.locator("#dms-delete")
    await remove.click()
    await expect(confirm).toBeVisible()
    await expect(confirm).toHaveAccessibleName(/^Delete this conversation for you only\? Key \d+ keeps its copy\.$/)
    await fits()
    await confirm.getByRole("button", {name: "Cancel"}).click()
    await expect(confirm).toBeHidden()
    await expect(page.locator("#dms-thread-list")).toContainText(`Hello at ${width}`)

    await remove.click()
    await confirm.getByRole("button", {name: "Delete"}).click()
    await expect(page).toHaveURL(new RegExp(`/classic/1/keys/${mine}/dms$`))
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
    expect(errors).toEqual([])
  })
}
