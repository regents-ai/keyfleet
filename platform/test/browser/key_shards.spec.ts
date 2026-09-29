import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {endShard, issueShard, landStep, prepareFleet, sellKey} from "./support/fleet_chain"
import {sentByStandIn, useStandInWallet} from "./support/stand_in_wallet"

// A key's owner issues, renews and ends shards from the key's page. Each
// press sends the step the server built to the stand-in wallet; the test lands
// it, then records on the made-up chain what the shard contract would log.
const fleet = "fleet_tech_classic"
const me = "0x1111111111111111111111111111111111111111"
const agentWallet = "0xdddddddddddddddddddddddddddddddddddddddd"
const shardsContract = "0x4444444444444444444444444444444444444444"
const issueSelector = "0x18d1ffc8"
const endSelector = "0x96f0fa4d"

test.beforeAll(() => {
  prepareFleet(fleet)
})

async function openKey(page: Page, key: number) {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  await page.goto(`/app/keys/${fleet}/${key}`)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  await useStandInWallet(page, me)
  return errors
}

const sentLine = (page: Page, panel: string, hash: string) =>
  page.locator(`#${panel}-sent li:has(code[title="${hash}"])`)

test("an owner issues a shard, renews it and ends it, and every press reaches the wallet", async ({page}) => {
  const key = sellKey(fleet, me)
  const errors = await openKey(page, key)
  await expect(page.locator("#key-no-shards")).toBeVisible()

  await page.locator("#key-shard-wallet").fill(agentWallet)
  await page.locator("#key-shard-days").fill("45")
  await expect(page.locator("#key-issue-shard-action-line")).toContainText("for 45 days")

  // Pressed twice before the wallet answers the first: both reach it.
  await page.locator("#key-issue-shard-button").click()
  await page.locator("#key-issue-shard-button").click()
  await expect.poll(async () => (await sentByStandIn(page)).length).toBe(2)
  const [issued] = await sentByStandIn(page)
  expect(issued.transaction.to.toLowerCase()).toBe(shardsContract)
  expect(issued.transaction.data.startsWith(issueSelector)).toBe(true)
  expect(issued.transaction.data.slice(-64)).toBe((45).toString(16).padStart(64, "0"))

  landStep(issued.hash, issued.transaction, true)
  await expect(sentLine(page, "key-issue-shard-action", issued.hash)).toContainText("The shard is issued")

  issueShard(fleet, key, agentWallet, 45)
  const shard = page.locator(`#key-shard-${agentWallet}`)
  await expect(shard).toContainText("No agent has signed in with it yet")
  await expect(page.locator("#key-no-shards")).toBeHidden()

  await page.locator(`#key-shard-renew-${agentWallet}`).click()
  await expect.poll(async () => (await sentByStandIn(page)).length).toBe(3)
  const renewed = (await sentByStandIn(page))[2]
  expect(renewed.transaction.to.toLowerCase()).toBe(shardsContract)
  expect(renewed.transaction.data.startsWith(issueSelector)).toBe(true)
  expect(renewed.transaction.data.slice(-64)).toBe((30).toString(16).padStart(64, "0"))

  await page.locator(`#key-shard-end-${agentWallet}`).click()
  await expect.poll(async () => (await sentByStandIn(page)).length).toBe(4)
  const ended = (await sentByStandIn(page))[3]
  expect(ended.transaction.to.toLowerCase()).toBe(shardsContract)
  expect(ended.transaction.data.startsWith(endSelector)).toBe(true)

  landStep(ended.hash, ended.transaction, true)
  await expect(sentLine(page, "key-shards-action", ended.hash)).toContainText("The shard has ended")

  endShard(fleet, key, agentWallet, me)
  await expect(shard).toBeHidden()
  await expect(page.locator("#key-no-shards")).toBeVisible()
  expect(errors).toEqual([])
})

test("a visitor sees a key's shards without the owner's buttons", async ({page}) => {
  const key = sellKey(fleet, "0x2222222222222222222222222222222222222222")
  issueShard(fleet, key, agentWallet, 10)
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  await page.goto(`/app/keys/${fleet}/${key}`)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()

  await expect(page.locator(`#key-shard-${agentWallet}`)).toBeVisible()
  await expect(page.locator(`#key-shard-end-${agentWallet}`)).toHaveCount(0)
  await expect(page.locator("#key-issue-shard")).toHaveCount(0)
  expect(errors).toEqual([])
})
