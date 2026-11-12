import {expect, test, type Locator, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {landStep, moveKeyUnread, offerRewards, prepareFleet, propose, sellKey} from "./support/fleet_chain"
import {sentByStandIn, useStandInWallet} from "./support/stand_in_wallet"

// Vote, Mark present and Claim all send every Key the wallet holds at the
// chain's latest block, a Key the site hasn't recorded yet among them, and a
// button is held back only when the chain shows the wallet no Key. Signed in
// as "other-account" (test/support/test_privy_verifier.ex), whose wallet no
// other spec gives a Syndicate Key; each press goes to a stand-in wallet.
const fleet = "fibonacci_syndicate"
const wallet = "0x3333333333333333333333333333333333333333"
const stranger = "0x9999999999999999999999999999999999999999"
const votesContract = `0x${"e1".repeat(20)}`
const rewardsContract = "0x6666666666666666666666666666666666666666"
const usdc = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
// The Builder Code every step's data ends with (RegentChain.BuilderCode).
const builderCode = "62635f7530393336306a6f0b0080218021802180218021802180218021"
// The collection names Key `key` of the Syndicate, fleet 2, by its id across every fleet.
const collectionId = (key: number) => BigInt(20_000_000_000) + BigInt(key)
const word = (value: bigint | number | string) =>
  (typeof value === "string" ? value.slice(2) : value.toString(16)).padStart(64, "0")

// What each press sends, as the contracts take it.
const present = (keys: number[]) =>
  `0x7d10accd${word(0x20)}${word(keys.length)}${keys.map(key => word(collectionId(key))).join("")}${builderCode}`
const voteYes = (proposal: number, keys: number[]) =>
  `0xb6e564ef${word(proposal)}${word(0x60)}${word(1)}${word(keys.length)}${keys.map(key => word(collectionId(key))).join("")}${builderCode}`
const claim = (keys: number[], asset: string) =>
  `0x2b14c842${word(0x40)}${word(0x40 + 0x20 * (keys.length + 1))}${word(keys.length)}${keys.map(key => word(collectionId(key))).join("")}${word(1)}${word(asset)}${builderCode}`

// A held-back button comes back once the panel reads the chain again, which it
// does every 15 seconds while a button is held back.
const reread = {timeout: 30_000}

async function open(page: Page, path: string) {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  await (await installAuthenticatedPrivy(page, "other-account")).establishLocalSession()
  await page.goto(path)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  await useStandInWallet(page, wallet)
  return errors
}

// Pressed twice, before the wallet has answered the first: both reach it.
async function pressTwice(page: Page, button: Locator) {
  const before = (await sentByStandIn(page)).length
  await button.click()
  await button.click()
  await expect.poll(async () => (await sentByStandIn(page)).length).toBe(before + 2)
  return (await sentByStandIn(page)).slice(before)
}

test.beforeAll(() => {
  prepareFleet(fleet)
})

test("Mark present is held back while the chain shows the wallet no Key, and sends a Key the site hasn't recorded yet", async ({
  page,
}) => {
  const key = sellKey(fleet, stranger)
  const errors = await open(page, "/syndicate/1/proposals")

  const mark = page.locator("#proposals-present-mark")
  await expect(mark).toBeDisabled()
  await expect(page.locator("#proposals-present-mark-why")).toHaveText("No Keys to use")

  // The Key reaches the wallet in a block the site hasn't read.
  moveKeyUnread(fleet, key, wallet)
  await expect(mark).toBeEnabled(reread)
  await expect(page.locator("#proposals-present-mark-why")).toBeHidden()
  await expect(page.locator(`#proposals-present-idle li[data-key="${key}"]`)).toContainText("Not present")

  const [first, second] = await pressTwice(page, mark)
  for (const {transaction} of [first, second]) {
    expect(transaction.to.toLowerCase()).toBe(votesContract)
    expect(transaction.data).toBe(present([key]))
  }

  // The Key leaves the wallet, again before the site reads it; once the
  // first mark lands the panel reads the chain again and holds the button back.
  moveKeyUnread(fleet, key, stranger)
  landStep(first.hash, first.transaction, true)
  await expect(mark).toBeDisabled()
  await expect(page.locator("#proposals-present-mark-why")).toHaveText("No Keys to use")
  expect(errors).toEqual([])
})

test("Vote sends a Key that reached the wallet before the site recorded it", async ({page}) => {
  const proposal = propose(fleet)
  const key = sellKey(fleet, stranger)
  moveKeyUnread(fleet, key, wallet)
  const errors = await open(page, `/syndicate/1/proposals/${proposal}`)

  const yes = page.locator("#proposal-vote-yes")
  await expect(yes).toBeEnabled()
  const sent = await pressTwice(page, yes)
  for (const {transaction} of sent) {
    expect(transaction.to.toLowerCase()).toBe(votesContract)
    expect(transaction.data).toBe(voteYes(proposal, [key]))
  }
  expect(errors).toEqual([])

  // The Key goes back, so the wallet holds only the Keys the next walk gives it.
  moveKeyUnread(fleet, key, stranger)
})

test("Claim all claims for the Keys the site has recorded and one it hasn't yet", async ({page}) => {
  const recorded = sellKey(fleet, wallet)
  const unread = sellKey(fleet, stranger)
  moveKeyUnread(fleet, unread, wallet)
  offerRewards(fleet, recorded, 1_000_000)
  offerRewards(fleet, unread, 1_500_000)
  const errors = await open(page, "/account")

  const claimAll = page.locator(`#account-claim-${fleet}-${usdc}`)
  await expect(claimAll).toHaveText("Claim 2.5 USDC")
  const sent = await pressTwice(page, claimAll)
  for (const {transaction} of sent) {
    expect(transaction.to.toLowerCase()).toBe(rewardsContract)
    expect(transaction.data).toBe(claim([recorded, unread], usdc))
  }
  expect(errors).toEqual([])
})
