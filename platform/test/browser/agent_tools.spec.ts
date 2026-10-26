import {randomBytes, randomUUID} from "node:crypto"
import {readFileSync} from "node:fs"
import {expect, test, type Page} from "@playwright/test"
import {type Answer, callSigned, callTool, heldTools, installModelContext, newAgent, pairAgent} from "./support/agent_tools"
import {prepareFleet, sayInPublic, sellKey} from "./support/fleet_chain"

// An agent in a person's browser uses Keyfleet through the tools its pages
// register (priv/tool_manifest.json), as the WebMCP acceptance of 16 October
// 2026 does on the live site: it finds them, reads without signing in, checks
// who it is, and talks in a fleet's Public room. Each signed tool is called
// as an agent calls it: the page prepares the exact request, the agent's own
// signer signs it, and the page sends it with that proof. The server checks
// each signature through a stand-in sign-in server (`Keyfleet.BrowserAgents`).
//
// The workspace steps are left out: the work graph's Python host does not run
// on this server, so a workspace write has nothing to write to.
const fleet = "fleet_tech_classic"
const fleetPath = "/classic/1"

type ManifestTool = {name: string; scope: string}
const manifest = JSON.parse(readFileSync(new URL("../../priv/tool_manifest.json", import.meta.url), "utf8")) as {
  tools: ManifestTool[]
}
const siteTools = manifest.tools.filter(tool => tool.scope === "site").map(tool => tool.name).sort()

const wallet = () => `0x${randomBytes(20).toString("hex")}`
const said = (text: string) => `${text} (${Math.random().toString(36).slice(2)})`

test.beforeAll(() => {
  prepareFleet(fleet)
})

test.beforeEach(async ({page}) => {
  await installModelContext(page)
})

// The page has offered the browser every one of its tools, and its own reads
// have landed, so leaving it never cuts one off inside the server's one
// transaction.
async function open(page: Page, path: string) {
  await page.goto(path)
  await settle(page)
}

async function settle(page: Page) {
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  await page.waitForLoadState("networkidle")
  await expectEverySiteTool(page)
}

// The browser holds each site tool once, and the page says it holds them all.
async function expectEverySiteTool(page: Page) {
  await expect(page.locator("html")).toHaveAttribute("data-webmcp-status", "connected")
  await expect
    .poll(async () => (await heldTools(page)).filter(name => siteTools.includes(name)).sort())
    .toEqual(siteTools)
}

test("the homepage and a fleet's pages offer every site tool, one set however the reader moves", async ({page}) => {
  await open(page, "/")
  await open(page, fleetPath)

  // Moving to another of the fleet's pages keeps the document, and its tools.
  await page.locator("#fleet-tab-proposals").click()
  await expect(page).toHaveURL(new RegExp(`${fleetPath}/proposals$`))
  await settle(page)

  // Back to a page left earlier, kept or loaded again, the page offers its tools once more.
  await page.goBack()
  await expect(page).toHaveURL(new RegExp(`${fleetPath}$`))
  await settle(page)
  await page.goBack()
  await expect(page).toHaveURL(/\/$/)
  await settle(page)
})

test("with nobody signed in and no proof, every public read answers, and an unknown fleet is refused", async ({page}) => {
  await open(page, fleetPath)

  for (const name of ["about", "docs"]) {
    const read = await callTool(page, name, {})
    expect(read, name).toMatchObject({ok: true, status: 200})
    expect(read.data.title.length, name).toBeGreaterThan(0)
    expect(read.data.markdown.length, name).toBeGreaterThan(0)
  }

  // The directory lists the fleet by the id fleets_show reads it with.
  const list = await callTool(page, "fleets_list", {})
  expect(list).toMatchObject({ok: true, status: 200})
  expect(list.data.fleets.map((entry: {id: string}) => entry.id)).toContain(fleet)
  expect(await callTool(page, "fleets_show", {fleet_id: fleet})).toMatchObject({ok: true, status: 200, data: {id: fleet}})

  for (const name of ["treasury_show", "proposals_list", "workspace_pulse"]) {
    const read = await callTool(page, name, {fleet_id: fleet})
    expect(read, name).toMatchObject({ok: true, status: 200, data: {fleet_id: fleet}})
  }

  const unknown = await callTool(page, "fleets_show", {fleet_id: "no_such_fleet"})
  expect(unknown).toMatchObject({ok: false, status: 404, error: {code: "fleet_unknown"}})
})

test("a paired agent learns who it is and who it acts for, and reading Credits spends none", async ({page}) => {
  const agent = newAgent()
  const person = wallet()
  pairAgent(agent, person)
  await open(page, "/")

  const whoami = await callSigned(page, agent, "agents_whoami", {})
  expect(whoami).toMatchObject({ok: true, status: 200})
  expect(whoami.data.data.agent.wallet).toBe(agent)
  expect(whoami.data.data.status).toBe("paired")

  const status = await callSigned(page, agent, "agents_status", {})
  expect(status).toMatchObject({ok: true, status: 200})
  expect(status.data.data.wallet).toBe(agent)
  expect(status.data.data.account.wallet_address).toBe(person)

  const first = await callSigned(page, agent, "account_balances", {})
  expect(first).toMatchObject({ok: true, status: 200})
  const again = await callSigned(page, agent, "account_balances", {})
  expect(again).toMatchObject({ok: true, status: 200})
  expect(again.data.credits).toEqual(first.data.credits)
})

test("a tool that needs a pairing refuses an unpaired agent, and answers once it is paired", async ({page}) => {
  const agent = newAgent()
  await open(page, "/")

  const refused = await callSigned(page, agent, "account_balances", {})
  expect(refused).toMatchObject({ok: false, status: 403, error: {code: "agent_not_paired"}})

  pairAgent(agent, wallet())
  expect(await callSigned(page, agent, "account_balances", {})).toMatchObject({ok: true, status: 200})
})

test("an agent posts one line in the Public room, and catching up again after a reconnect repeats nothing and misses nothing", async ({page}) => {
  // Another member has spoken in the Public room; the agent's person holds a Key of the fleet.
  sayInPublic(fleet, wallet(), said("The survey starts at noon."))
  const person = wallet()
  const key = sellKey(fleet, person)
  const agent = newAgent()
  pairAgent(agent, person)
  await open(page, fleetPath)

  expect(await callSigned(page, agent, "agents_join", {name: "Browser tools agent", declared_harness: "test"}))
    .toMatchObject({ok: true, status: 200})

  const rooms = await callSigned(page, agent, "rooms_list", {fleet_id: fleet})
  expect(rooms).toMatchObject({ok: true, status: 200})
  expect(rooms.data.rooms.map((room: {slug: string}) => room.slug)).toContain("general")

  const general = await callSigned(page, agent, "rooms_messages", {fleet_id: fleet, slug: "general"})
  expect(general).toMatchObject({ok: true, status: 200})
  const readTo: number = general.data.room.head_seq

  const line = said("Hull survey started.")
  const sent = await callSigned(page, agent, "rooms_post", {
    fleet_id: fleet,
    slug: "general",
    body: line,
    idempotency_key: randomUUID(),
  })
  expect(sent).toMatchObject({ok: true, status: 201, data: {message: {body: line, as_key: key}}})

  const sync = (afterSeq: number) =>
    callSigned(page, agent, "fleets_sync", {
      fleet_id: fleet,
      rooms: [{slug: "general", after_seq: afterSeq}],
      graph: {after_seq: 0},
      proposals: {after_seq: 0},
      run: {kind: "session"},
    })
  type Synced = {slug: string; cursor: number; messages: {id: string; body: string}[]}
  const generalIn = (answer: Answer): Synced => answer.data.rooms.find((room: Synced) => room.slug === "general")

  const caughtUp = await sync(readTo)
  expect(caughtUp).toMatchObject({ok: true, status: 200})
  const first = generalIn(caughtUp)
  expect(first.messages.filter(message => message.id === sent.data.message.id)).toHaveLength(1)

  // The agent drops its connection, and another member speaks while it is away.
  await page.reload()
  await settle(page)
  const meanwhile = said("Survey moved to one o'clock.")
  sayInPublic(fleet, wallet(), meanwhile)

  // Catching up from where the last catch-up ended repeats none of it, and has what was said since.
  const resumed = await sync(first.cursor)
  expect(resumed).toMatchObject({ok: true, status: 200})
  const since = generalIn(resumed).messages
  const seen = new Set(first.messages.map(message => message.id))
  expect(since.filter(message => seen.has(message.id))).toEqual([])
  expect(since.filter(message => message.body === meanwhile)).toHaveLength(1)
})
