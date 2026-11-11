import {expect, test, type Page} from "@playwright/test"
import {newAgent, pairPerson} from "./support/agent_tools"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {endShard, issueShard, landStep, prepareFleet, sellKey} from "./support/fleet_chain"
import {sentByStandIn, useStandInWallet} from "./support/stand_in_wallet"

// A key's owner issues, renews and ends shards from the key's page: a paired
// agent's in one press, any other wallet typed under Other wallet. Each press
// sends the step the server built to the stand-in wallet; the test lands it,
// then records on the made-up chain what the shard contract would log. Signed
// in as "did:privy:verified", whose wallet is `me`.
const fleet = "fleet_tech_classic"
const person = "did:privy:verified"
const me = "0x1111111111111111111111111111111111111111"
const agentWallet = "0xdddddddddddddddddddddddddddddddddddddddd"
const shardsContract = "0x4444444444444444444444444444444444444444"
const issueSelector = "0x0423d500"
const endSelector = "0x8dbf85b7"

test.beforeAll(() => {
  prepareFleet(fleet)
})

async function openKey(page: Page, key: number) {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  await page.goto(`/classic/1/keys/${key}`)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  await useStandInWallet(page, me)
  return errors
}

// The days a shard is issued for: the third word after the selector, after
// where the keys are and the wallet.
const days = (data: string) => Number(BigInt(`0x${data.slice(10 + 2 * 64, 10 + 3 * 64)}`))

const sentLine = (page: Page, panel: string, hash: string) =>
  page.locator(`#${panel}-sent li:has(#${panel}-sent-${hash})`)

test("an owner gives a paired agent a shard in one press, and it lands in the Shards list", async ({page}) => {
  const agent = newAgent()
  const name = `Press ${agent.slice(2, 8)}`
  pairPerson(agent, person, name)
  const key = sellKey(fleet, me)
  const errors = await openKey(page, key)

  const row = page.locator(`#key-issue-${agent}`)
  await expect(row).toContainText(name)
  await expect(page.locator(`#key-issue-${agent}-action-line`)).toContainText(`Key ${key} to`)
  await expect(page.locator(`#key-issue-${agent}-action-line`)).toContainText("30 days")

  // Pressed twice before the wallet answers the first: both reach it.
  const press = page.locator(`#key-issue-${agent}-button`)
  await expect(press).toBeEnabled()
  await press.click()
  await press.click()
  await expect.poll(async () => (await sentByStandIn(page)).length).toBe(2)
  const [issued] = await sentByStandIn(page)
  expect(issued.transaction.to.toLowerCase()).toBe(shardsContract)
  expect(issued.transaction.data.startsWith(issueSelector)).toBe(true)
  expect(issued.transaction.data.toLowerCase()).toContain(agent.slice(2))
  expect(days(issued.transaction.data)).toBe(30)

  landStep(issued.hash, issued.transaction, true)
  await expect(sentLine(page, `key-issue-${agent}-action`, issued.hash)).toContainText("Done.")

  issueShard(fleet, key, agent, 30)
  await expect(page.locator(`#key-shard-${agent}`)).toBeVisible()
  await expect(page.locator(`#key-shard-renew-${agent}`)).toBeVisible()
  await expect(row).toHaveCount(0)
  expect(errors).toEqual([])
})

test("an owner issues a shard to another wallet, renews it and ends it, and every press reaches the wallet", async ({page}) => {
  const key = sellKey(fleet, me)
  const errors = await openKey(page, key)
  await expect(page.locator("#key-no-shards")).toBeVisible()

  const other = page.locator("#key-other-wallet")
  await expect(other).not.toHaveAttribute("open")
  await other.locator("summary").click()
  await page.locator("#key-shard-wallet").fill(agentWallet)
  await page.locator("#key-shard-days").fill("45")
  await expect(page.locator("#key-issue-shard-action-line")).toContainText("45 days")

  // Pressed twice before the wallet answers the first: both reach it.
  await page.locator("#key-issue-shard-button").click()
  await page.locator("#key-issue-shard-button").click()
  await expect.poll(async () => (await sentByStandIn(page)).length).toBe(2)
  const [issued] = await sentByStandIn(page)
  expect(issued.transaction.to.toLowerCase()).toBe(shardsContract)
  expect(issued.transaction.data.startsWith(issueSelector)).toBe(true)
  expect(days(issued.transaction.data)).toBe(45)

  landStep(issued.hash, issued.transaction, true)
  await expect(sentLine(page, "key-issue-shard-action", issued.hash)).toContainText("Done.")

  issueShard(fleet, key, agentWallet, 45)
  const shard = page.locator(`#key-shard-${agentWallet}`)
  await expect(shard).toContainText("No agent yet")
  await expect(page.locator("#key-no-shards")).toBeHidden()

  await page.locator(`#key-shard-renew-${agentWallet}`).click()
  await expect.poll(async () => (await sentByStandIn(page)).length).toBe(3)
  const renewed = (await sentByStandIn(page))[2]
  expect(renewed.transaction.to.toLowerCase()).toBe(shardsContract)
  expect(renewed.transaction.data.startsWith(issueSelector)).toBe(true)
  expect(days(renewed.transaction.data)).toBe(30)

  await page.locator(`#key-shard-end-${agentWallet}`).click()
  await expect.poll(async () => (await sentByStandIn(page)).length).toBe(4)
  const ended = (await sentByStandIn(page))[3]
  expect(ended.transaction.to.toLowerCase()).toBe(shardsContract)
  expect(ended.transaction.data.startsWith(endSelector)).toBe(true)

  landStep(ended.hash, ended.transaction, true)
  await expect(sentLine(page, "key-shards-action", ended.hash)).toContainText("Done.")

  endShard(fleet, key, agentWallet, me)
  await expect(shard).toBeHidden()
  await expect(page.locator("#key-no-shards")).toBeVisible()
  expect(errors).toEqual([])
})

// Signed out, the key's present card asks Privy for the open wallet, and this
// test server has no Privy app for it, so the page's own errors aren't
// checked here.
test("a visitor sees a key's shards without the owner's buttons", async ({page}) => {
  const key = sellKey(fleet, "0x2222222222222222222222222222222222222222")
  issueShard(fleet, key, agentWallet, 10)
  await page.goto(`/classic/1/keys/${key}`)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()

  await expect(page.locator(`#key-shard-${agentWallet}`)).toBeVisible()
  await expect(page.locator(`#key-shard-end-${agentWallet}`)).toHaveCount(0)
  await expect(page.locator("#key-issue-shard")).toHaveCount(0)
})

test("on a phone, the holder's OpenSea link is a whole thumb tall", async ({page}) => {
  const key = sellKey(fleet, "0x2222222222222222222222222222222222222222")
  await page.setViewportSize({width: 390, height: 844})
  await page.goto(`/classic/1/keys/${key}`)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()

  const box = await page.locator("#key-owner-opensea").boundingBox()
  expect(box!.height).toBeGreaterThanOrEqual(44)
})
