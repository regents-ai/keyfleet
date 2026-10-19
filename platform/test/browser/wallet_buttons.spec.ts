import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {allowUsdc, landStep, offerRewards, prepareFleet, refuseDraw, sellKey} from "./support/fleet_chain"
import {sentByStandIn, useStandInWallet} from "./support/stand_in_wallet"

// Wallet buttons send the steps the server built for them, from a stand-in
// wallet made Privy's active wallet in the page. The server follows each
// sent step on the made-up chain, where the test lands it.
const fleet = "fleet_tech_classic"
const me = "0x1111111111111111111111111111111111111111"
const stranger = "0x9999999999999999999999999999999999999999"
const fleetContract = "0x5555555555555555555555555555555555555555"
const keysContract = "0xa1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
// The collection names Key `key` of the Classic, fleet 1, by its id across every fleet.
const collectionId = (key: number) => BigInt(10_000_000_000) + BigInt(key)
const rewardsContract = "0x6666666666666666666666666666666666666666"
const usdc = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
const approveSelector = "0x095ea7b3"
const purchaseSelector = "0xb48eb184"
const requestRevealSelector = "0x40261cdd"

// Opens the fleet's page, signed in as `bearer` unless it is null, at its
// Buying a key panel; returns the page's uncaught errors.
async function openBuying(page: Page, bearer: string | null = "valid") {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  if (bearer) await (await installAuthenticatedPrivy(page, bearer)).establishLocalSession()
  await page.goto(`/classic/1`)
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

  await expect(page.locator("#buy-key-order-from")).toHaveText("Sending from 0x1111..1111 on Base.")
  await expect(page.locator("#buy-key-approve")).toBeVisible()
  await expect(page.locator("#buy-key-button")).toBeDisabled()
  await expect(page.locator("#buy-key-button-why")).toHaveText("Approve USDC first")

  // Pressed twice before the wallet answers the first: both reach it.
  await page.locator("#buy-key-approve").click()
  await page.locator("#buy-key-approve").click()
  await expect.poll(async () => (await sentByStandIn(page)).length).toBe(2)
  const [first, second] = await sentByStandIn(page)
  for (const {transaction} of [first, second]) {
    expect(transaction.to.toLowerCase()).toBe(usdc)
    expect(transaction.data.startsWith(approveSelector)).toBe(true)
  }

  // The purchase can be pressed as soon as an approval is sent, before it
  // lands, and nothing is done until the server reads it.
  await expect(page.locator("#buy-key-button")).toBeEnabled()
  await expect(page.locator("#buy-key-button-why")).toBeHidden()
  await expect(sentLine(page, first.hash)).toContainText("Sent. Waiting for Base.")
  await expect(sentLine(page, second.hash)).toContainText("Sent. Waiting for Base.")

  // The first approval lands; the steps are built again from the allowance
  // it gave, the most the purchase may cost, which leaves only the purchase.
  allowUsdc(me, Number(BigInt(`0x${first.transaction.data.slice(-64)}`)))
  landStep(first.hash, first.transaction, true)
  await expect(sentLine(page, first.hash)).toHaveAttribute("data-state", "confirmed")
  await expect(sentLine(page, first.hash)).toContainText("Approved. Now press the next button.")
  await expect(page.locator("#buy-key-approve")).toBeHidden()

  await page.locator("#buy-key-button").click()
  await expect.poll(async () => (await sentByStandIn(page)).length).toBe(3)
  const bought = (await sentByStandIn(page))[2]
  expect(bought.transaction.to.toLowerCase()).toBe(fleetContract)
  expect(bought.transaction.data.startsWith(purchaseSelector)).toBe(true)

  // A purchase the contract refuses says so, and Buy stays to press again.
  landStep(bought.hash, bought.transaction, false)
  await expect(sentLine(page, bought.hash)).toHaveAttribute("data-state", "reverted")
  await expect(sentLine(page, bought.hash)).toContainText("Not bought. No USDC was taken.")
  await page.locator("#buy-key-button").click()
  await expect.poll(async () => (await sentByStandIn(page)).length).toBe(4)
  expect(errors).toEqual([])
})

test("a wallet the account doesn't link: a note names both, and a press sends nothing and says why", async ({page}) => {
  const errors = await openBuying(page)
  await useStandInWallet(page, stranger)

  // The figures stay on the account's own wallet.
  await expect(page.locator("#buy-key-order-mismatch")).toHaveText(
    "Your wallet is on 0x9999..9999, which isn't linked to this account. Switch to 0x1111..1111.",
  )
  await expect(page.locator("#buy-key-order-from")).toBeHidden()
  await expect(page.locator("#buy-key-approve")).toBeVisible()

  await page.locator("#buy-key-approve").click()
  await expect(pressNote(page)).toHaveText(
    "Your wallet is on 0x9999..9999, which isn't linked to this account. Switch to 0x1111..1111. Nothing was sent.",
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
  await page.goto(`/classic/1?key=${key}`)
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

test("a key whose draw was turned down can be asked again: every press reaches the wallet, and the server says when the draw is on its way", async ({
  page,
}) => {
  const key = sellKey(fleet, stranger)
  refuseDraw(fleet, key, true)
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  await page.goto(`/classic/1?key=${key}`)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  await useStandInWallet(page, me)

  // Anyone may ask again, not only the key's holder: pressed twice, both reach the wallet.
  const again = page.locator("#key-profile-reveal-again")
  await expect(again).toHaveText("Ask again")
  await again.click()
  await again.click()
  await expect.poll(async () => (await sentByStandIn(page)).length).toBe(2)
  const [first, second] = await sentByStandIn(page)
  for (const {transaction} of [first, second]) {
    expect(transaction.to.toLowerCase()).toBe(keysContract)
    expect(transaction.data).toBe(requestRevealSelector + collectionId(key).toString(16).padStart(64, "0"))
  }

  // The first is accepted; the server reads that the draw is on its way.
  refuseDraw(fleet, key, false)
  landStep(first.hash, first.transaction, true)
  await expect(page.locator(`#key-profile-reveal-action-sent li:has(code[title="${first.hash}"])`)).toContainText(
    "Done.",
  )
  // The chain now has the request, so another is certain to be refused: the
  // button stays, turned off, and says why.
  await expect(again).toBeDisabled()
  await expect(page.locator("#key-profile-reveal-again-why")).toHaveText("Draw on its way")

  // The repeat reaches the chain, which refuses it.
  landStep(second.hash, second.transaction, false)
  await expect(page.locator(`#key-profile-reveal-action-sent li:has(code[title="${second.hash}"])`)).toContainText(
    "Nothing asked. The draw may be on its way.",
  )
  expect(errors).toEqual([])
})
