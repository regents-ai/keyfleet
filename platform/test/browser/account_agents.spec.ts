import {expect, test, type Page} from "@playwright/test"
import {newAgent, pairPerson, useCode} from "./support/agent_tools"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {issueShard, prepareFleet, sellKey} from "./support/fleet_chain"
import {sentByStandIn, useStandInWallet} from "./support/stand_in_wallet"

// A person manages their paired agents on the Account page, as on regents.sh:
// See what it has done opens the agent's window, Done closes it, and Unpair,
// once confirmed in a window of its own, takes the agent off the account. The window is the shared
// cut-corner dialog, on a wide screen and on a phone.
const person = "did:privy:verified"

async function signIn(page: Page) {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  return errors
}

async function openAccount(page: Page) {
  await page.goto("/account")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
}

for (const viewport of [{width: 1280, height: 800}, {width: 390, height: 844}]) {
  test(`at ${viewport.width} px, an agent's window opens and closes, and Unpair takes the agent off the account`, async ({page}) => {
    await page.setViewportSize(viewport)
    const name = `Astra ${viewport.width}`
    pairPerson(newAgent(), person, name)
    const errors = await signIn(page)
    await openAccount(page)

    const row = page.locator("#account-agents li", {hasText: name})
    const dialog = page.locator("#account-agent-dialog")
    await row.getByRole("button", {name: `See what ${name} has done`}).click()
    await expect(dialog).toBeVisible()
    await expect(dialog.getByRole("heading", {name})).toBeVisible()
    await expect(dialog).toContainText("spent for you on Regent sites.")
    const box = (await dialog.boundingBox())!
    expect(box.x).toBeGreaterThanOrEqual(0)
    expect(box.x + box.width).toBeLessThanOrEqual(viewport.width)

    await dialog.getByRole("button", {name: "Done"}).click()
    await expect(dialog).toBeHidden()

    await row.getByRole("button", {name: `See what ${name} has done`}).click()
    await expect(dialog).toBeVisible()
    const confirm = page.locator("#account-unpair-dialog")
    await dialog.getByRole("button", {name: "Unpair"}).click()
    await expect(confirm.getByRole("heading", {name: `Unpair ${name}?`})).toBeFocused()
    await confirm.getByRole("button", {name: "Cancel"}).click()
    await expect(confirm).toBeHidden()
    await expect(dialog.getByRole("button", {name: "Unpair"})).toBeFocused()

    await dialog.getByRole("button", {name: "Unpair"}).click()
    await confirm.getByRole("button", {name: "Unpair"}).click()

    await expect(confirm).toBeHidden()
    await expect(dialog).toBeHidden()
    await expect(row).toHaveCount(0)
    await expect(page.locator("#account-agents [role=status]")).toHaveText(
      `${name} is unpaired. It will need a new code to pair again.`,
    )
    expect(errors).toEqual([])
  })
}

test("on a 320 px phone, each account tab is a whole thumb wide and the four fit without scrolling", async ({page}) => {
  await page.setViewportSize({width: 320, height: 700})
  await signIn(page)
  await openAccount(page)

  const tabs = page.locator("#shell-tabs a")
  await expect(tabs).toHaveCount(4)
  for (const tab of await tabs.all()) {
    const box = (await tab.boundingBox())!
    expect.soft(box.width, await tab.innerText()).toBeGreaterThanOrEqual(44)
    expect.soft(box.height, await tab.innerText()).toBeGreaterThanOrEqual(44)
  }
  expect(await page.locator("#shell-tabs").evaluate(strip => strip.scrollWidth <= strip.clientWidth)).toBe(true)
})

// Once an agent pairs, the person is offered a shard of their own Key for it:
// the link opens that Key's New shard form with the agent's wallet filled in,
// and the press reaches the wallet. With the shard on the chain, the agent's
// row names the Key.
test("an agent that pairs is offered a shard of the person's Key, and its row then names the Key", async ({page}) => {
  const fleet = "fleet_tech_classic"
  const me = "0x1111111111111111111111111111111111111111"
  prepareFleet(fleet)
  sellKey(fleet, me)
  const agent = newAgent()
  const name = `Shard ${agent.slice(2, 8)}`
  const errors = await signIn(page)
  await openAccount(page)

  const box = page.locator("#account-pairing-box")
  const next = page.locator("#account-pairing-box-next")
  const radio = box.getByRole("radio", {name: "Hermes", exact: true})
  await radio.locator("xpath=ancestor::label").click()
  const message = box.locator("pre")
  await expect(message).toContainText(/Pairing code:\s*\S{12,}/)
  const before = (await next.boundingBox())!.height
  const [, code] = (await message.innerText()).match(/Pairing code:\s*(\S+)/)!
  useCode(agent, code, name)

  const give = page.locator("#account-pairing-box-give-shard")
  await expect(give).toHaveText(`Give ${name} a shard`)
  expect((await next.boundingBox())!.height).toBe(before)
  await expect(page.locator("#account-agents li", {hasText: name}).getByRole("link", {name: "Give it a shard"})).toBeVisible()

  await give.click()
  await expect(page.locator("#key-shard-wallet")).toHaveValue(agent)
  const key = Number(new URL(page.url()).pathname.split("/").pop())
  expect(new URL(page.url()).pathname).toBe(`/classic/1/keys/${key}`)
  await useStandInWallet(page, me)
  await page.locator("#key-issue-shard-button").click()
  await expect.poll(async () => (await sentByStandIn(page)).length).toBe(1)
  const [{transaction}] = await sentByStandIn(page)
  expect(transaction.data.toLowerCase()).toContain(agent.slice(2))

  issueShard(fleet, key, agent, 30)
  await openAccount(page)
  const row = page.locator("#account-agents li", {hasText: name})
  await expect(row.getByRole("link", {name: `Classic #1 Key ${key}`})).toHaveAttribute("href", `/classic/1/keys/${key}`)
  await expect(row.getByRole("link", {name: "Give it a shard"})).toHaveCount(0)
  expect(errors).toEqual([])
})
