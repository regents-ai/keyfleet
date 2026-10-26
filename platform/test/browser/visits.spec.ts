import {existsSync, readFileSync} from "node:fs"
import {expect, test} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {prepareFleet, sayInPublic} from "./support/fleet_chain"

// A visit can be told again from its lines alone (KeyfleetWeb.VisitLog). The
// walk's person opens a room and mutes a Key from one of its posts, and the
// lines the server wrote for that visit (config/runtime.exs) say so in order:
// the request, the page, the mute the site saved and the press that asked for
// it. Every line carries the same visit and the same one-way code for the
// person, holds only the visit fields, and holds nothing anyone wrote and no
// wallet. The poster is this walk's own, and the walk unmutes at the end, so
// the room's other walks never meet its mute.
const fleet = "fleet_tech_classic"
const loud = "0x7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a"

// The walk's person (Keyfleet.TestPrivyVerifier, "valid").
const wallet = `0x${"1".repeat(40)}`

type Line = {
  time: string
  severity: string
  message: string
  metadata: {
    visit?: string
    actor?: string
    surface?: string
    request_id?: string
    event?: {name: string; where: string; outcome?: string; ms?: number}
  }
}

const fields = ["actor", "event", "request_id", "surface", "visit"]

test.beforeAll(() => {
  prepareFleet(fleet)
})

function lines(visit: string): Line[] {
  const file = "tmp/walk-lines.jsonl"
  if (!existsSync(file)) return []
  return readFileSync(file, "utf8")
    .split("\n")
    .filter(text => text.includes(visit))
    .map(text => JSON.parse(text) as Line)
    .filter(line => line.metadata.visit === visit && line.metadata.event)
}

const step = (line: Line) => `${line.metadata.event!.name} ${line.metadata.event!.where}`

test("opening a room and muting a Key replays in order from the visit's lines", async ({page, context}) => {
  const said = `Buy my fan art, every hour. (${Math.random().toString(36).slice(2)})`
  sayInPublic(fleet, loud, said)
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))

  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  await page.goto("/classic/1?room=general")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  // A post names the poster's first Key, so the walk mutes from its own post.
  const post = page.locator("#rooms-thread li").filter({hasText: said})
  const key = (await post.getByRole("link", {name: /^Key \d+$/}).textContent())!.match(/\d+/)![0]
  await post.getByRole("button", {name: `Mute Key ${key}`}).click()
  await expect(page.locator(`#rooms-muted-${key}`)).toContainText(`Key ${key}`)

  const visit = (await context.cookies()).find(cookie => cookie.name === "_visit")!.value
  await expect.poll(() => lines(visit).map(step)).toContain("press ShellLive:mute_key")
  const told = lines(visit)
  const steps = told.map(step)

  expect(steps[0]).toBe("request /classic/1")
  const order = ["request /classic/1", "page /classic/1", "action mute.mute", "press ShellLive:mute_key"].map(wanted =>
    steps.indexOf(wanted),
  )
  expect(order.every(index => index >= 0)).toBe(true)
  expect([...order].sort((a, b) => a - b)).toEqual(order)
  expect(told.find(line => step(line) === "press ShellLive:mute_key")!.metadata.event!.outcome).toBe("ok")

  const actors = [...new Set(told.map(line => line.metadata.actor))]
  expect(actors).toHaveLength(1)
  expect(actors[0]).toMatch(/^person:[0-9a-f]{16}$/)

  for (const line of told) {
    expect(Object.keys(line).sort()).toEqual(["message", "metadata", "severity", "time"])
    expect(Object.keys(line.metadata).every(key => fields.includes(key))).toBe(true)
    expect(Object.keys(line.metadata.event!).every(key => ["name", "where", "outcome", "ms"].includes(key))).toBe(true)
    const text = JSON.stringify(line)
    for (const written of [said, wallet, loud, "did:privy"]) expect(text).not.toContain(written)
  }

  await page.locator(`#rooms-unmute-${key}`).click()
  await expect(page.locator("#rooms-muted")).toHaveCount(0)
  expect(errors).toEqual([])
})
