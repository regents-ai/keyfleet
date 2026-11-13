import {existsSync, readFileSync} from "node:fs"
import {expect, test, type Locator, type Page} from "@playwright/test"
import {newAgent, useCode} from "./support/agent_tools"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {allowUsdc, landStep, markPresent, prepareFleet, sellKey} from "./support/fleet_chain"
import {sentByStandIn, useStandInWallet} from "./support/stand_in_wallet"

// A new owner buys a Key in the Buy Key window, is told they're in, and "Set
// up your agent" brings them to the fleet's page. Pair and Mark present stand
// under its tabs: Pair opens the pairing box and goes once an agent is paired,
// which the visit's lines record (KeyfleetWeb.VisitLog); Mark present marks the owner's idle Key in one press, every press reaching
// the wallet, and goes once the Key is present. Signed in as "other-account"
// (test/support/test_privy_verifier.ex), whose account no other spec pairs an
// agent with, nor gives a Classic Key. Each press goes to a stand-in wallet;
// the test lands it, then records on the made-up chain what the contract logs.
const fleet = "fleet_tech_classic"
const owner = "0x3333333333333333333333333333333333333333"
const fleetContract = "0x5555555555555555555555555555555555555555"
const votesContract = `0x${"e0".repeat(20)}`
const purchaseSelector = "0xb48eb184"
// The Builder Code every step's data ends with (RegentChain.BuilderCode).
const builderCode = "62635f7530393336306a6f0b0080218021802180218021802180218021"
// The collection names Key `key` of the Classic, fleet 1, by its id across every fleet.
const collectionId = (key: number) => BigInt(10_000_000_000) + BigInt(key)
const word = (value: bigint | number) => value.toString(16).padStart(64, "0")
// Marking Keys present, as the vote contract takes it.
const present = (keys: number[]) =>
  `0x7d10accd${word(0x20)}${word(keys.length)}${keys.map(key => word(collectionId(key))).join("")}${builderCode}`

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

// Pressed twice, before the wallet has answered the first: both reach it.
async function pressTwice(page: Page, button: Locator) {
  const before = (await sentByStandIn(page)).length
  await button.click()
  await button.click()
  await expect.poll(async () => (await sentByStandIn(page)).length).toBe(before + 2)
  return (await sentByStandIn(page)).slice(before)
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

// The code in the pairing box once an agent is chosen; the box opens on its
// list of agents, which a choice closes.
async function pairingCode(page: Page, agent: string) {
  const box = page.locator("#fleet-prompts-pairing")
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

// What the server's lines (config/runtime.exs) say a visit did, each as its
// event's name and where.
function visitEvents(visit: string) {
  const file = "tmp/walk-lines.jsonl"
  if (!existsSync(file)) return []
  return readFileSync(file, "utf8")
    .split("\n")
    .filter(text => text.includes(visit))
    .map(text => JSON.parse(text).metadata)
    .filter(metadata => metadata.visit === visit && metadata.event)
    .map(({event}) => `${event.name} ${event.where}`)
}

test.beforeAll(() => {
  prepareFleet(fleet)
  allowUsdc(owner, 1_000_000_000_000)
})

test("a new owner pairs an agent and marks their idle Key present from the top of the fleet's page", async ({page}) => {
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

  const pair = page.locator("#fleet-prompts-pair")
  const mark = page.locator("#fleet-prompts-mark")
  await expect(pair).toBeVisible()
  await expect(mark).toBeEnabled()
  await expect(page.locator("#fleet-prompts-idle")).toHaveText("1")

  // Side by side under the tabs, and on a phone still on screen.
  const tabs = (await page.locator(".fleet-bar").boundingBox())!
  const pairBox = (await pair.boundingBox())!
  const markBox = (await mark.boundingBox())!
  expect(pairBox.y).toBeGreaterThanOrEqual(tabs.y + tabs.height)
  expect(Math.abs(pairBox.y - markBox.y)).toBeLessThanOrEqual(1)
  await page.setViewportSize({width: 390, height: 844})
  for (const button of [pair, mark]) {
    const {x, width} = (await button.boundingBox())!
    expect(x).toBeGreaterThanOrEqual(0)
    expect(x + width).toBeLessThanOrEqual(390)
  }
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390)
  await page.setViewportSize({width: 1280, height: 720})

  await pair.click()
  await expect(pair).toHaveAttribute("aria-expanded", "true")
  const agent = newAgent()
  useCode(agent, await pairingCode(page, "Dots"), "Astra")
  await expect(pair).toHaveCount(0)
  await expect(page.locator("#fleet-prompts-pairing")).toHaveCount(0)
  const visit = (await page.context().cookies()).find(cookie => cookie.name === "_visit")!.value
  await expect.poll(() => visitEvents(visit)).toContain("step agent_paired")
  await expect(mark).toBeEnabled()

  await useStandInWallet(page, owner)
  const [first, second] = await pressTwice(page, mark)
  for (const {transaction} of [first, second]) {
    expect(transaction.to.toLowerCase()).toBe(votesContract)
    expect(transaction.data).toBe(present([key]))
  }

  landStep(first.hash, first.transaction, true)
  markPresent(fleet, owner)
  await expect(mark).toHaveCount(0)
  await expect(page.locator("#fleet-prompts > *")).toHaveCount(0)
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
