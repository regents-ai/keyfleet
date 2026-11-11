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

test("a fleet's Pair New Agent opens the pairing window, which copies its message", async ({page}) => {
  const errors = await signIn(page)
  await open(page, `/classic/1`)
  await page.locator("#fleet-pair").click()
  await expect(page.locator("#shell-pairing")).toBeVisible()
  const box = page.locator("#shell-pairing-box")
  await box.getByRole("radio", {name: "Hermes", exact: true}).locator("xpath=ancestor::label").click()
  const message = box.locator("pre")
  await expect(message).toContainText(/Pairing code:\s*\S{12,}/)

  await copies(page, "shell-pairing-box-copy", (await message.locator("code").textContent())!)
  expect(errors).toEqual([])
})

test("the Wallets tab copies the account's wallet", async ({page}) => {
  const errors = await signIn(page)
  await open(page, "/account/wallets")

  await copies(page, `wallets-list-${me}-address-copy`, me)
  expect(errors).toEqual([])
})

test("a key's page copies the wallet of an agent with a shard of it", async ({page}) => {
  const key = sellKey(fleet, me)
  shardKey(fleet, key)
  const errors = await signIn(page)
  await open(page, `/classic/1/keys/${key}`)

  await copies(page, `key-shard-address-${agentWallet}-copy`, agentWallet)
  expect(errors).toEqual([])
})
