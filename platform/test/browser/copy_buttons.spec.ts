import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {prepareFleet, sellKey, shardKey} from "./support/fleet_chain"

// Every copy button on Keyfleet's pages puts its value on the clipboard and
// says "Copied" on the button and to screen readers. The key page's needs a
// key with a shard, so these run with the chain.
const fleet = "fleet_tech_classic"
const me = "0x1111111111111111111111111111111111111111"
// The agent `shardKey` gives a shard to, as `Keyfleet.BrowserChain` names it.
const agentWallet = "0xcccccccccccccccccccccccccccccccccccccccc"

test.use({permissions: ["clipboard-read", "clipboard-write"]})

test.beforeAll(() => {
  prepareFleet(fleet)
})

async function signIn(page: Page) {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  return errors
}

async function open(page: Page, path: string) {
  await page.goto(path)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
}

async function copies(page: Page, id: string, value: string) {
  await page.evaluate(() => navigator.clipboard.writeText(""))
  await page.locator(`#${id}`).click()
  await expect(page.locator(`#${id}`)).toHaveAttribute("data-copy-state", "copied")
  await expect(page.locator(`#${id}-status`)).toHaveText("Copied")
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(value)
  // The answer goes after a moment, and the button is as it was.
  await expect(page.locator(`#${id}`)).not.toHaveAttribute("data-copy-state")
  await expect(page.locator(`#${id}-status`)).toHaveText("")
}

test("a fleet's Send your agent copies its instruction", async ({page}) => {
  const errors = await signIn(page)
  await open(page, `/app/fleets/${fleet}`)
  await page.locator("#fleet-send-agent").click()
  await expect(page.locator("#fleet-send-agent-dialog")).toBeVisible()

  await copies(
    page,
    "fleet-send-agent-copy",
    "Visit keyfleet.ai and read its joining guide. Then look at the Classic #1 fleet.",
  )
  expect(errors).toEqual([])
})

test("the Wallets tab copies the account's wallet", async ({page}) => {
  const errors = await signIn(page)
  await open(page, "/account/wallets")

  await copies(page, "account-wallet-copy", me)
  expect(errors).toEqual([])
})

test("a key's page copies the wallet of an agent with a shard of it", async ({page}) => {
  const key = sellKey(fleet, me)
  shardKey(fleet, key)
  const errors = await signIn(page)
  await open(page, `/app/keys/${fleet}/${key}`)

  await copies(page, `key-shard-address-${agentWallet}`, agentWallet)
  expect(errors).toEqual([])
})
