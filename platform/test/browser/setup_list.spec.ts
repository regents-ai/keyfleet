import {expect, test, type Page} from "@playwright/test"
import {checkInDaily, newAgent, useCode} from "./support/agent_tools"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {allowUsdc, issueShard, landStep, markPresent, prepareFleet, sellKey} from "./support/fleet_chain"
import {sentByStandIn, useStandInWallet} from "./support/stand_in_wallet"

// A new owner buys a Key in the Buy Key window, is told they're in, and "Set
// up your agent" brings them to the fleet's page, where the setup list takes
// them through Pair, Shard, Daily run and Present: only the first step not
// done is open, and once all four are done the list is gone. Signed in as
// "other-account" (test/support/test_privy_verifier.ex), whose account no
// other spec pairs an agent with. Each press goes to a stand-in wallet; the
// test lands it, then records on the made-up chain what the contract logs.
const fleet = "fleet_tech_classic"
const owner = "0x3333333333333333333333333333333333333333"
const fleetContract = "0x5555555555555555555555555555555555555555"
const shardsContract = "0x4444444444444444444444444444444444444444"
const purchaseSelector = "0xb48eb184"
const issueSelector = "0x0423d500"

const list = (page: Page) => page.locator("#fleet-setup")
const openStep = (page: Page) => list(page).locator('li[aria-current="step"]')

async function connected(page: Page) {
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
}

// The next transaction the stand-in wallet sends, once `press` has pressed.
async function sendsOne(page: Page, press: () => Promise<void>) {
  const before = (await sentByStandIn(page)).length
  await press()
  await expect.poll(async () => (await sentByStandIn(page)).length).toBe(before + 1)
  return (await sentByStandIn(page))[before]
}

// Buys the next Key in the Buy Key window from the stand-in wallet and lands
// the purchase.
async function buy(page: Page) {
  await page.locator("#shell-get-key").click()
  await expect(page.locator("dialog#buy-key #buy-key-title")).toBeVisible()
  await useStandInWallet(page, owner)
  const bought = await sendsOne(page, () => page.locator("#buy-key-button").click())
  expect(bought.transaction.to.toLowerCase()).toBe(fleetContract)
  expect(bought.transaction.data.startsWith(purchaseSelector)).toBe(true)
  landStep(bought.hash, bought.transaction, true)
}

// Once the purchase lands, "You're in" is wholly on screen with focus on
// "Set up your agent", which the words above it describe.
async function toldYoureIn(page: Page) {
  const youreIn = page.locator("#buy-key-in")
  await expect(youreIn).toContainText("You’re in")
  const setUp = youreIn.getByRole("button", {name: "Set up your agent"})
  await expect(setUp).toBeFocused()
  await expect(setUp).toHaveAccessibleDescription("You’re in Your Key is in your wallet. Next, set up your agent.")
  await expect(youreIn).toBeInViewport({ratio: 1})
  return setUp
}

// The code in the setup list's pairing box once an agent is chosen; the box
// opens on its list of agents, which a choice closes.
async function pairingCode(page: Page, agent: string) {
  const box = page.locator("#fleet-setup-pairing")
  const radio = box.getByRole("radio", {name: agent, exact: true})
  const choices = box.locator("details")
  if (!(await choices.evaluate(details => (details as HTMLDetailsElement).open))) await choices.locator("summary").click()
  await radio.locator("xpath=ancestor::label").click()
  await expect(radio).toBeChecked()
  const message = box.locator("pre")
  await expect(message).toContainText(/Pairing code:\s*\S{12,}/)
  const [, code] = (await message.innerText()).match(/Pairing code:\s*(\S+)/)!
  return code
}

test.beforeAll(() => {
  prepareFleet(fleet)
  allowUsdc(owner, 1_000_000_000_000)
})

test("a new owner is sent from the purchase to the setup list, which is gone once every step is done", async ({page}) => {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  await page.setViewportSize({width: 1280, height: 720})
  await (await installAuthenticatedPrivy(page, "other-account")).establishLocalSession()
  await page.goto("/classic/1")
  await connected(page)

  await buy(page)
  const setUp = await toldYoureIn(page)
  const key = sellKey(fleet, owner)

  await setUp.click()
  await expect(page.locator("dialog#buy-key")).toBeHidden()
  await expect(page).toHaveURL(/\/classic\/1$/)
  await connected(page)
  await expect(list(page)).toBeVisible()
  await expect(list(page).getByRole("heading", {name: "Setup"})).toBeVisible()
  await expect(list(page).locator(".setup-list__title")).toHaveText(["Pair", "Shard", "Daily run", "Present"])
  await expect(openStep(page)).toHaveAttribute("id", "fleet-setup-pair")

  // On a phone the open list stays on screen.
  await page.setViewportSize({width: 390, height: 844})
  const {x, width} = (await list(page).boundingBox())!
  expect(x).toBeGreaterThanOrEqual(0)
  expect(x + width).toBeLessThanOrEqual(390)
  await page.setViewportSize({width: 1280, height: 720})

  const agent = newAgent()
  useCode(agent, await pairingCode(page, "Dots"), "Astra")
  await expect(openStep(page)).toHaveAttribute("id", "fleet-setup-shard")
  await expect(page.locator("#fleet-setup-pair")).toHaveAttribute("data-done", "")

  await useStandInWallet(page, owner)
  const shard = page.locator("#fleet-setup-shard-button")
  await expect(shard).toHaveText("Give Astra a shard")
  const issued = await sendsOne(page, () => shard.click())
  expect(issued.transaction.to.toLowerCase()).toBe(shardsContract)
  expect(issued.transaction.data.startsWith(issueSelector)).toBe(true)
  expect(issued.transaction.data.toLowerCase()).toContain(agent.slice(2).toLowerCase())
  landStep(issued.hash, issued.transaction, true)
  issueShard(fleet, key, agent, 30)
  await expect(openStep(page)).toHaveAttribute("id", "fleet-setup-run")

  checkInDaily(agent, fleet)
  await expect(openStep(page)).toHaveAttribute("id", "fleet-setup-present")

  markPresent(fleet, owner)
  await expect(list(page)).toBeHidden()
  await expect(list(page).locator("li")).toHaveCount(0)
  expect(errors).toEqual([])
})

// On a phone the window scrolls to "You're in" too. The owner already holds
// a Key from the walk above, so this purchase is their second.
test("on a phone, the purchase lands with You're in and Set up your agent on screen", async ({page}) => {
  await page.setViewportSize({width: 390, height: 844})
  await (await installAuthenticatedPrivy(page, "other-account")).establishLocalSession()
  await page.goto("/classic/1")
  await connected(page)

  await buy(page)
  await toldYoureIn(page)
})
