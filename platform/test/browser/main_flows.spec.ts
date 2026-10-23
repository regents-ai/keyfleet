import {expect, test, type Page} from "@playwright/test"
import {
  belowFirstScreen,
  expectComfortable,
  expectConnected,
  expectOnFirstScreen,
  visit,
  watchErrors,
} from "./support/first_visit"

// The walk a first-time visitor takes, signed out, on the device in their
// hand: the homepage and Classic #1's sale, Classic #1's own page, the
// Regents Club and its five tabs, a room anyone can read, and its polls, which
// are for its Keys. Each
// step must fit the screen, keep its controls big enough to press, raise no
// error and stay connected.
//
// The site is as it launches (support/club_world.ts): Classic #1's sales open
// soon, so its sale waits and its page has no tabs yet; the Regents Club is
// open. Everything below is reached through the pages' own links.

const club = "/app/fleets/regents_club"

async function openClub(page: Page) {
  await visit(page, club)
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
  await expect(page.getByRole("heading", {level: 1, name: "Regents Club"})).toBeVisible()
}

test("the homepage shows Classic #1, its price, and Buy waiting for the sale", async ({page}) => {
  const errors = watchErrors(page)
  await visit(page, "/")

  await expect(page.locator("#home-hero-fleet")).toHaveText("Classic #1 now")
  const facts = page.locator("#home-classic-facts")
  await expect(facts).toContainText("Open soon")
  await expect(page.locator("#home-classic-price")).toHaveText(/^[0-9][0-9.]* USDC$/)
  await expectOnFirstScreen(page, facts, "Classic #1's Keys and price")

  const buy = page.locator("#home-buy-next-key")
  await expect(buy).toContainText("Buy Next Key")
  await expect(buy).toBeDisabled()
  await expect(page.locator("#home-buy-price")).toHaveText("Key 1 · 10 USDC")
  await expect(page.locator("#home-buy-why")).toHaveText("Sales open soon")
  // The hero puts the Key's card above its button, so on a phone the button
  // sits below the first screen. That is a layout choice, so the run reports
  // how far below rather than failing on it.
  const below = await belowFirstScreen(page, buy)
  test.info().annotations.push({type: "Buy Next Key below the first screen", description: `${below}px`})
  await expectComfortable(page, errors)

  // Classic #1's own "Buy Key" waits for the sale too, with the same reason.
  await expect(page.locator("#home-classic-buy")).toHaveAttribute("aria-disabled", "true")
  await expect(page.locator("#home-classic-why")).toHaveText("Sales open soon")
  await expectConnected(page)
})

test("Classic #1's page says its sales open soon and leads back to the fleets", async ({page}) => {
  const errors = watchErrors(page)
  await visit(page, "/")
  await page.locator("#home-classic-public").click()

  await expect(page).toHaveURL(/\/classic\/1$/)
  await expectConnected(page)
  await expect(page.getByRole("heading", {level: 1, name: "Classic #1"})).toBeVisible()
  await expect(page.locator("#fleet-soon-title")).toHaveText("Sales open soon")
  // Until it opens there is nothing behind its tabs, so it shows none.
  await expect(page.locator("#fleet-tabs")).toHaveCount(0)
  const back = page.locator("#fleet-soon").getByRole("link", {name: "See the fleets"})
  await expectOnFirstScreen(page, back, "See the fleets")
  await expectComfortable(page, errors)

  await back.click()
  await expect(page).toHaveURL(/\/(#home-classic)?$/)
  await expect(page.locator("#public-home")).toBeVisible()
  await expectConnected(page)
})

test("the Regents Club opens on its hall, and each of its five tabs opens", async ({page}) => {
  const errors = watchErrors(page)
  await openClub(page)

  // The way in comes first: Club Keys come with a Pass, and are bought on OpenSea.
  await expect(page.locator("#fleet-entry")).toContainText("Club Keys come with a Regents Club Pass.")
  await expectOnFirstScreen(page, page.locator("#fleet-opensea"), "Buy Key on OpenSea")
  await expect(page.locator("#fleet-tab-hall")).toHaveAttribute("aria-current", "page")
  await expect(page.locator("#fleet-feed-list > li").first()).toBeVisible()
  await expectComfortable(page, errors)

  const tabs = [
    {tab: "#fleet-tab-treasury", path: /\/treasury$/, shows: "#treasury-page"},
    {tab: "#fleet-tab-proposals", path: /\/proposals$/, shows: "#proposals-page"},
    {tab: "#fleet-tab-workspace", path: /\/workspace$/, shows: "#workspace-page"},
    {tab: "#fleet-tab-keys", path: /\?view=members$/, shows: "#fleet-members"},
    {tab: "#fleet-tab-hall", path: /regents_club$/, shows: "#fleet-hall"},
  ]
  for (const {tab, path, shows} of tabs) {
    await page.locator(tab).click()
    await expect(page).toHaveURL(path)
    await expect(page.locator(shows)).toBeVisible()
    await expect(page.locator(tab)).toHaveAttribute("aria-current", "page")
    await expect(page.getByRole("heading", {level: 1, name: "Regents Club"})).toBeVisible()
    await expectComfortable(page, errors)
  }

  // Under Keys, Grid shows the Keys on the fleet's map.
  await page.locator("#fleet-tab-keys").click()
  await page.locator("#fleet-keys-members-grid").click()
  await expect(page).toHaveURL(/\?view=map$/)
  await expect(page.locator("#fleet-map")).toBeVisible()
  await expectComfortable(page, errors)
})

test("the Public room opens from the hall, and anyone can read it", async ({page}) => {
  const errors = watchErrors(page)
  await openClub(page)

  await page.locator("#fleet-channels").getByRole("link", {name: "Public", exact: true}).click()
  await expect(page).toHaveURL(/\?room=general$/)
  const title = page.getByRole("heading", {level: 2, name: "Public", exact: true})
  await expectOnFirstScreen(page, title, "the room's name")
  await expect(page.locator("#rooms-thread-list [data-post]").first()).toBeVisible()
  await expect(page.locator("#rooms-thread")).toContainText("Anyone can read this room.")
  await expectComfortable(page, errors)
})

test("the polls are for the fleet's Keys: the hall doesn't list them, and their address says so", async ({page}) => {
  const errors = watchErrors(page)
  await openClub(page)
  await expect(page.locator("#fleet-polls-link")).toHaveCount(0)

  await visit(page, `${club}/polls`)
  await expectOnFirstScreen(page, page.locator("#polls-locked"), "who the polls are for")
  await expect(page.locator("#polls-locked")).toContainText("Keys only")
  await expect(page.locator("#polls-sign-in")).toBeVisible()
  await expectComfortable(page, errors)
})
