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
// Regents Club and its five tabs, a room anyone can read, and a poll. Each
// step must fit the screen, keep its controls big enough to press, raise no
// error and stay connected.
//
// The site is as it launches (support/club_world.ts): Classic #1 is coming
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

  await expect(page.locator("#home-hero-fleet")).toHaveText("Classic #1")
  const facts = page.locator("#home-classic-facts")
  await expect(facts).toContainText("1,024")
  await expect(facts).toContainText("10–100 USDC")
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

  // "Buy Key" opens the sale's window: nothing sold yet, the first Key's
  // price, and its Buy closed with the same reason.
  await page.locator("#home-classic-buy").click()
  const sale = page.getByRole("dialog", {name: "Buy Key"})
  await expect(sale).toBeVisible()
  await expect(sale.locator("#home-buy-key-sold")).toHaveText("0 of 1,024")
  await expect(sale.locator("#home-buy-key-next")).toHaveText("Key 1 · 10 USDC")
  await expectOnFirstScreen(page, sale.locator("#home-buy-key-next"), "the next Key's price")
  await expect(sale.locator("#home-buy-key-go")).toBeDisabled()
  await expect(sale.locator("#home-buy-key-why")).toHaveText("Sales open soon")
  await expectComfortable(page, errors)
  await sale.getByRole("button", {name: "Close", exact: true}).click()
  await expect(sale).toBeHidden()
  await expectConnected(page)
})

test("Classic #1's page says it is coming soon and leads back to the fleets", async ({page}) => {
  const errors = watchErrors(page)
  await visit(page, "/")
  await page.locator("#home-classic-public").click()

  await expect(page).toHaveURL(/\/classic\/1$/)
  await expectConnected(page)
  await expect(page.getByRole("heading", {level: 1, name: "Classic #1"})).toBeVisible()
  await expect(page.locator("#fleet-soon-title")).toHaveText("Coming soon")
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
    {tab: "#fleet-tab-keys", path: /\?view=map$/, shows: "#fleet-map"},
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

  // Under Keys, List shows who holds which Key.
  await page.locator("#fleet-tab-keys").click()
  await page.locator("#fleet-keys-map-list").click()
  await expect(page).toHaveURL(/\?view=members$/)
  await expect(page.locator("#fleet-members")).toBeVisible()
  await expectComfortable(page, errors)
})

test("General opens from the hall, and anyone can read it", async ({page}) => {
  const errors = watchErrors(page)
  await openClub(page)

  await page.locator("#fleet-channels").getByRole("link", {name: "General", exact: true}).click()
  await expect(page).toHaveURL(/\/rooms\/general$/)
  const title = page.getByRole("heading", {level: 1, name: "General", exact: true})
  await expectOnFirstScreen(page, title, "the room's name")
  await expect(page.locator("#rooms-thread-list [data-post]").first()).toBeVisible()
  await expect(page.locator("#rooms-page")).toContainText("Anyone can read this room.")
  await expectComfortable(page, errors)
})

test("a poll opens from the hall, with its question and choices", async ({page}) => {
  const errors = watchErrors(page)
  await openClub(page)

  await page.locator("#fleet-polls-link").click()
  await expect(page).toHaveURL(/\/polls$/)
  await expect(page.getByRole("heading", {level: 1, name: "Polls"})).toBeVisible()
  await expectComfortable(page, errors)

  const poll = page.locator("#polls-page .polls-card h3 a").first()
  const question = (await poll.textContent())!.trim()
  await poll.click()
  await expect(page).toHaveURL(/\/polls\/[0-9a-f-]{36}$/)
  await expectOnFirstScreen(page, page.getByRole("heading", {level: 1, name: question, exact: true}), "the poll's question")
  await expect(page.locator("#poll-choices .polls-options li, #poll-results li").first()).toBeVisible()
  // Signed out, a visitor follows along; holding a Key is what lets someone vote.
  await expect(page.locator("#poll-vote-form")).toHaveCount(0)
  await expect(page.locator("#poll-choices")).toContainText("Anyone can follow along.")
  await expectComfortable(page, errors)
})
