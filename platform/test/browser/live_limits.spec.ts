import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {prepareFleet} from "./support/fleet_chain"

// A page goes live whatever address it is opened at, and a form typed or
// pasted past its fields' limits keeps its live connection: the browser keeps
// each field to its limit, and the site's own note says what is too long. A
// message larger than the connection reads closes it, and the page opens
// another, so each walk counts the page's live connections.
const fleet = "fibonacci_syndicate"
// A connection closed for its size is open again within a second
// (LiveView's reconnectAfterMs), so two seconds with none new is none.
const settle = 2_000

function liveConnections(page: Page) {
  const opened: string[] = []
  page.on("websocket", socket => {
    if (new URL(socket.url()).pathname === "/live/websocket") opened.push(socket.url())
  })
  return opened
}

function pageErrors(page: Page) {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  return errors
}

const live = (page: Page) => expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()

test.beforeAll(() => {
  prepareFleet(fleet)
})

test("a page opened with a #fragment longer than a live message goes live without it, and keeps a short one", async ({
  page,
}) => {
  const opened = liveConnections(page)
  const errors = pageErrors(page)

  await page.goto(`/#${"a".repeat(60_000)}`)
  await live(page)
  expect(await page.evaluate(() => window.location.hash)).toBe("")
  await page.waitForTimeout(settle)
  expect(opened).toHaveLength(1)

  // Opened afresh, not moved within the same page.
  await page.goto("about:blank")
  await page.goto("/#keys")
  await live(page)
  expect(await page.evaluate(() => window.location.hash)).toBe("#keys")
  await page.waitForTimeout(settle)
  expect(opened).toHaveLength(2)
  expect(errors).toEqual([])
})

test("a proposal pasted past every field's limit keeps the page live, and the site says what is too long", async ({
  page,
}) => {
  const errors = pageErrors(page)
  await (await installAuthenticatedPrivy(page, "other-account")).establishLocalSession()
  const opened = liveConnections(page)
  await page.goto("/syndicate/1/proposals")
  await live(page)

  const form = page.locator("#propose-action-form")
  const line = page.locator("#propose-action-line")
  // Pasted as a person pastes, in letters of three bytes, more than the field
  // takes, once the page has opened the field for the kind chosen.
  const paste = async (name: string) => {
    const field = form.locator(`[name="${name}"]`)
    const most = Number(await field.getAttribute("maxlength"))
    await expect(field.locator("xpath=ancestor-or-self::*[@inert]")).toHaveCount(0)
    await field.focus()
    await expect(field).toBeFocused()
    await page.keyboard.insertText("提".repeat(most + 1_000))
    await expect(field).toHaveJSProperty("value", "提".repeat(most))
  }

  await form.locator('[name="key"]').fill("1")
  await paste("text")
  await expect(line).toContainText("too long")

  // Each kind's fields, kept by the form when another kind is chosen, so the
  // last change sends every field at its limit.
  for (const [kind, names] of [
    ["pay", ["share", "recipient"]],
    ["rate", ["rate"]],
    ["edits", ["target"]],
    ["launch", ["name", "symbol", "description", "website", "image"]],
  ] as const) {
    await form.locator('[name="kind"]').selectOption(kind)
    for (const name of names) await paste(name)
  }

  await page.waitForTimeout(settle)
  await live(page)
  await expect(line).toContainText("too long")
  expect(opened).toHaveLength(1)
  expect(errors).toEqual([])
})
