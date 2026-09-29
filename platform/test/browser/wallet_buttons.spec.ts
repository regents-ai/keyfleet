import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {allowUsdc, landStep, offerRewards, prepareFleet, sellKey} from "./support/fleet_chain"
import {sentByStandIn, useStandInWallet} from "./support/stand_in_wallet"

// Wallet buttons send the steps the server built for them, from a stand-in
// wallet made Privy's active wallet in the page. The server follows each
// sent step on the made-up chain, where the test lands it.
const fleet = "fleet_tech_classic"
const me = "0x1111111111111111111111111111111111111111"
const stranger = "0x9999999999999999999999999999999999999999"
const fleetContract = "0x5555555555555555555555555555555555555555"
const rewardsContract = "0x6666666666666666666666666666666666666666"
const usdc = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
const approveSelector = "0x095ea7b3"
const purchaseSelector = "0x98968f15"

// Opens the fleet's page, signed in as `bearer` unless it is null, at its
// Buying a key panel; returns the page's uncaught errors.
async function openBuying(page: Page, bearer: string | null = "valid") {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  if (bearer) await (await installAuthenticatedPrivy(page, bearer)).establishLocalSession()
  await page.goto(`/app/fleets/${fleet}`)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  await page.locator("#fleet-get-key").click()
  await expect(page.locator("#buy-key-title")).toBeVisible()
  return errors
}

const sentLine = (page: Page, hash: string) => page.locator(`#buy-key-order-sent li:has(code[title="${hash}"])`)
const pressNote = (page: Page) => page.locator("#buy-key-order-press-note")

test.beforeAll(() => {
  prepareFleet(fleet)
})

test.beforeEach(() => {
  allowUsdc(me, 0)
})

test("an approval, then the purchase: every press reaches the wallet, and each is followed until the server has an answer", async ({
  page,
}) => {
  const errors = await openBuying(page)
  await useStandInWallet(page, me)

  await expect(page.locator("#buy-key-order-from")).toHaveText("Sending from 0x1111..1111 on Ethereum.")
  await expect(page.locator("#buy-key-approve")).toBeVisible()
  await expect(page.locator("#buy-key-button")).toBeHidden()

  // Pressed twice before the wallet answers the first: both reach it.
  await page.locator("#buy-key-approve").click()
  await page.locator("#buy-key-approve").click()
  await expect.poll(async () => (await sentByStandIn(page)).length).toBe(2)
  const [first, second] = await sentByStandIn(page)
  for (const {transaction} of [first, second]) {
    expect(transaction.to.toLowerCase()).toBe(usdc)
    expect(transaction.data.startsWith(approveSelector)).toBe(true)
  }

  // The purchase can be pressed as soon as an approval is sent, and nothing
  // is done until the server reads it.
  await expect(page.locator("#buy-key-button")).toBeVisible()
  await expect(sentLine(page, first.hash)).toContainText("Sent. Waiting for Ethereum.")
  await expect(sentLine(page, second.hash)).toContainText("Sent. Waiting for Ethereum.")

  // The first approval lands; the steps are built again from the allowance
  // it gave, exactly the next key's price, which leaves only the purchase.
  allowUsdc(me, Number(BigInt(`0x${first.transaction.data.slice(-64)}`)))
  landStep(first.hash, first.transaction, true)
  await expect(sentLine(page, first.hash)).toHaveAttribute("data-state", "confirmed")
  await expect(sentLine(page, first.hash)).toContainText("Approved. Now press Buy key.")
  await expect(page.locator("#buy-key-approve")).toBeHidden()

  await page.locator("#buy-key-button").click()
  await expect.poll(async () => (await sentByStandIn(page)).length).toBe(3)
  const bought = (await sentByStandIn(page))[2]
  expect(bought.transaction.to.toLowerCase()).toBe(fleetContract)
  expect(bought.transaction.data.startsWith(purchaseSelector)).toBe(true)

  // A purchase the contract refuses says so, and Buy stays to press again.
  landStep(bought.hash, bought.transaction, false)
  await expect(sentLine(page, bought.hash)).toHaveAttribute("data-state", "reverted")
  await expect(sentLine(page, bought.hash)).toContainText("The purchase didn’t go through and no USDC was taken.")
  await page.locator("#buy-key-button").click()
  await expect.poll(async () => (await sentByStandIn(page)).length).toBe(4)
  expect(errors).toEqual([])
})

test("a wallet the account doesn't link: a note names both, and a press sends nothing and says why", async ({page}) => {
  const errors = await openBuying(page)
  await useStandInWallet(page, stranger)

  // The figures stay on the account's own wallet.
  await expect(page.locator("#buy-key-order-mismatch")).toHaveText(
    "You're signed in with 0x1111..1111, but your wallet app has 0x9999..9999 open. Switch to a wallet on your account to send from here.",
  )
  await expect(page.locator("#buy-key-order-from")).toBeHidden()
  await expect(page.locator("#buy-key-approve")).toBeVisible()

  await page.locator("#buy-key-approve").click()
  await expect(pressNote(page)).toHaveText(
    "Switch to a wallet on your account in your wallet app, then press again. Nothing was sent.",
  )
  expect(await sentByStandIn(page)).toEqual([])

  // Switching to the account's wallet sends from it.
  await useStandInWallet(page, me)
  await expect(page.locator("#buy-key-order-mismatch")).toBeHidden()
  await page.locator("#buy-key-approve").click()
  await expect.poll(async () => (await sentByStandIn(page)).length).toBe(1)
  expect(errors).toEqual([])
})

test("a press the wallet declines says so, and the next press still reaches the wallet", async ({page}) => {
  const errors = await openBuying(page)
  await useStandInWallet(page, me, "decline")

  await page.locator("#buy-key-approve").click()
  await expect(pressNote(page)).toHaveText("Your wallet declined this. Nothing was sent.")

  await useStandInWallet(page, me, "send")
  await page.locator("#buy-key-approve").click()
  await expect.poll(async () => (await sentByStandIn(page)).length).toBe(1)
  await expect(pressNote(page)).toBeHidden()
  expect(errors).toEqual([])
})

// Signed out, the page starts Privy's sign-in, which this test server has no
// Privy app for, so the page's own errors aren't checked here.
test("signed out, a press sends nothing, whatever wallet is open, and asks to sign in", async ({page}) => {
  await openBuying(page, null)
  await useStandInWallet(page, me)

  await expect(page.locator("#buy-key-order-from")).toBeHidden()
  await page.locator("#buy-key-button").click()
  await expect(pressNote(page)).toHaveText("Sign in to send this. Nothing was sent.")
  expect(await sentByStandIn(page)).toEqual([])
})

test("a key's income is claimed to the wallet that holds it, and the claim is followed until it lands", async ({
  page,
}) => {
  const key = sellKey(fleet, me)
  offerRewards(fleet, key, 2_500_000)
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  await page.goto(`/app/fleets/${fleet}?key=${key}`)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  await useStandInWallet(page, me)

  const claim = page.locator(`#key-profile-claim-${usdc}`)
  await expect(claim).toHaveText("Claim 2.5 USDC")
  await claim.click()
  await expect.poll(async () => (await sentByStandIn(page)).length).toBe(1)
  const [claimed] = await sentByStandIn(page)
  expect(claimed.transaction.to.toLowerCase()).toBe(rewardsContract)

  landStep(claimed.hash, claimed.transaction, true)
  await expect(page.locator(`#key-profile-claim-action-sent li:has(code[title="${claimed.hash}"])`)).toContainText(
    "Done.",
  )
  expect(errors).toEqual([])
})
