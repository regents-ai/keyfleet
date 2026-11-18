import {keccak_256} from "@noble/hashes/sha3.js"
import {bytesToHex, utf8ToBytes} from "@noble/hashes/utils.js"
import {expect, test, type Locator, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {prepareFleet, sellKey} from "./support/fleet_chain"
import {sentByStandIn, useStandInWallet} from "./support/stand_in_wallet"

// A page goes live whatever address it is opened at, and a form typed or
// pasted past its fields' limits keeps its live connection: the browser keeps
// each field to its limit, and the site's own note says what is too long, for
// the kind of proposal chosen alone. A message larger than the connection
// reads closes it, and the page opens another, so each walk counts the page's
// live connections.
const fleet = "fibonacci_syndicate"
// The wallet the "valid" account links (test/support/test_privy_verifier.ex).
const me = "0x1111111111111111111111111111111111111111"
const votesContract = `0x${"e1".repeat(20)}`
// propose(uint256,bytes32,(address,uint256,bytes)[]), for Key `key` of the
// Syndicate, fleet 2, named by its id across every fleet.
const proposeFor = (key: number) => `0x4d51a20c${(BigInt(20_000_000_000) + BigInt(key)).toString(16).padStart(64, "0")}`
// The Builder Code every step's data ends with (RegentChain.BuilderCode).
const builderCode = "62635f7530393336306a6f0b0080218021802180218021802180218021"
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

// Costly failure: the page can't take its long fragment off an address whose
// path starts //, which the browser would read as another site's, so it
// never goes live.
test("a page at a path that starts // goes live without its long #fragment, and a page keeps one of 256 characters", async ({
  page,
  baseURL,
}) => {
  const opened = liveConnections(page)
  const errors = pageErrors(page)

  for (const [address, fragment] of [
    [`//syndicate/1/proposals#${"a".repeat(300)}`, ""],
    [`/syndicate/1/proposals#${"a".repeat(256)}`, `#${"a".repeat(256)}`],
  ]) {
    const path = address.split("#")[0]
    await page.goto("about:blank")
    await page.goto(`${baseURL}${address}`)
    await live(page)
    expect(await page.evaluate(() => [window.location.pathname, window.location.hash])).toEqual([path, fragment])
  }

  await page.waitForTimeout(settle)
  expect(opened).toHaveLength(2)
  expect(errors).toEqual([])
})

// Costly failure: an address with a name and password before the host hides
// them from the page's own reading of it, so writing that reading back names
// another address, the browser refuses it, and the page never goes live.
test("a page at an address with a name before its host goes live without its long #fragment, keeping its path and query", async ({
  page,
  baseURL,
}) => {
  const opened = liveConnections(page)
  const errors = pageErrors(page)
  const {protocol, host} = new URL(baseURL!)

  await page.goto(`${protocol}//someone:secret@${host}/syndicate/1/proposals?from=a#${"a".repeat(300)}`)
  await live(page)
  expect(await page.evaluate(() => [window.location.pathname, window.location.search, window.location.hash])).toEqual([
    "/syndicate/1/proposals",
    "?from=a",
    "",
  ])

  await page.waitForTimeout(settle)
  expect(opened).toHaveLength(1)
  expect(errors).toEqual([])
})

// Costly failure: a #fragment whose %-escapes spell no text throws as the page
// looks for what it names, before the page joins, so it never goes live.
test("a page opened with a #fragment that spells no text goes live, and a link to one breaks nothing", async ({page}) => {
  const opened = liveConnections(page)
  const errors = pageErrors(page)

  await page.goto("/syndicate/1/proposals#%E0")
  await live(page)
  expect(await page.evaluate(() => window.location.hash)).toBe("#%E0")
  await page.evaluate(() => {
    const link = document.createElement("a")
    link.href = "#%E0"
    link.textContent = "Nowhere"
    document.body.append(link)
  })
  await page.getByRole("link", {name: "Nowhere"}).click()

  await page.waitForTimeout(settle)
  expect(opened).toHaveLength(1)
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

// Costly failure: a field a box cut, still in that box once the kind is changed
// to a decision, holds the decision back, and no wallet is asked. A rate and a
// launch's image link are each held to their box's count.
test("a rate and a launch's image link too long, left in their hidden boxes, never hold back a decision; the launch is refused", async ({
  page,
}) => {
  const errors = pageErrors(page)
  const key = sellKey(fleet, me)
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  await page.goto("/syndicate/1/proposals")
  await live(page)
  await useStandInWallet(page, me)

  const form = page.locator("#propose-action-form")
  const line = page.locator("#propose-action-line")
  const pressNote = page.locator("#propose-action-press-note")
  const press = page.locator('#propose-action [data-onchain-step="propose"]')
  const rate = form.locator('[name="rate"]')
  const image = form.locator('[name="image"]')
  const tooLong = "The image link is too long: 256 characters at most."
  // Each box keeps two characters more than the site takes.
  const link = `https://example.com/${"coin/".repeat(60)}coin.png`
  const kept = link.slice(0, 258)
  // Pasted as a person pastes, once the page has opened the box for the kind chosen.
  const paste = async (box: Locator, text: string) => {
    await expect(box.locator("xpath=ancestor-or-self::*[@inert]")).toHaveCount(0)
    await box.focus()
    await expect(box).toBeFocused()
    await page.keyboard.insertText(text)
  }

  await form.locator('[name="key"]').fill(String(key))
  await form.locator('[name="kind"]').selectOption("rate")
  await paste(rate, "1".repeat(200))
  await expect(rate).toHaveJSProperty("value", "1".repeat(102))
  await expect(line).toHaveText("The rate is too long: 100 characters at most.")

  await form.locator('[name="kind"]').selectOption("launch")
  for (const [name, value] of [
    ["text", "Launch the fleet's coin"],
    ["name", "Fleet Coin"],
    ["symbol", "FLT"],
    ["description", "The fleet's own token"],
    ["website", "https://example.com"],
  ]) {
    await form.locator(`[name="${name}"]`).fill(value)
  }
  await paste(image, link)
  await expect(image).toHaveJSProperty("value", kept)
  await expect(line).toHaveText(tooLong)

  // The control: the launch, which carries the image link, is refused and
  // asks no wallet.
  await press.click()
  await expect(pressNote).toHaveText(tooLong)
  expect(await sentByStandIn(page)).toEqual([])

  await form.locator('[name="kind"]').selectOption("decision")
  await form.locator('[name="text"]').fill("Fund the docs for a month.")
  for (const box of [rate, image]) await expect(box.locator("xpath=ancestor-or-self::*[@inert]")).toHaveCount(1)
  await expect(rate).toHaveJSProperty("value", "1".repeat(102))
  await expect(image).toHaveJSProperty("value", kept)
  await expect(line).toContainText("A decision; nothing moves.")

  await press.click()
  await expect.poll(async () => (await sentByStandIn(page)).length).toBe(1)
  const [{transaction}] = await sentByStandIn(page)
  expect(transaction.to.toLowerCase()).toBe(votesContract)
  expect(transaction.data.startsWith(proposeFor(key))).toBe(true)
  expect(transaction.data.endsWith(builderCode)).toBe(true)
  expect(errors).toEqual([])
})

// Costly failure: a paste that starts with blank lines or spaces, cut by its
// box, loses its end, and the wallet is asked to sign what is left. A box is
// measured as typed, spaces and line ends included, so what it cut is refused,
// while the longest words the site takes, a line break inside them, reach the
// wallet whole.
test("words and an image link pasted after blank lines or spaces past their box ask no wallet; the longest words do", async ({
  page,
}) => {
  const errors = pageErrors(page)
  const key = sellKey(fleet, me)
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  await page.goto("/syndicate/1/proposals")
  await live(page)
  await useStandInWallet(page, me)

  const form = page.locator("#propose-action-form")
  const line = page.locator("#propose-action-line")
  const pressNote = page.locator("#propose-action-press-note")
  const press = page.locator('#propose-action [data-onchain-step="propose"]')
  const text = form.locator('[name="text"]')
  const image = form.locator('[name="image"]')
  const wordsTooLong = "The proposal is too long: 4000 characters at most."
  const linkTooLong = "The image link is too long: 256 characters at most."
  const link = `https://example.com/${"coin/".repeat(60)}coin.png`
  // Pasted as a person pastes, once the page has opened the box for the kind chosen.
  const paste = async (box: Locator, value: string) => {
    await expect(box.locator("xpath=ancestor-or-self::*[@inert]")).toHaveCount(0)
    await box.fill("")
    await box.focus()
    await expect(box).toBeFocused()
    await page.keyboard.insertText(value)
  }

  await form.locator('[name="key"]').fill(String(key))
  await paste(text, `\n\n${"w".repeat(4_030)}`)
  await expect(text).toHaveJSProperty("value", `\n\n${"w".repeat(4_000)}`)
  await expect(line).toHaveText(wordsTooLong)
  await press.click()
  await expect(pressNote).toHaveText(wordsTooLong)

  await form.locator('[name="kind"]').selectOption("launch")
  for (const [name, value] of [
    ["text", "Launch the fleet's coin"],
    ["name", "Fleet Coin"],
    ["symbol", "FLT"],
    ["description", "The fleet's own token"],
    ["website", "https://example.com"],
  ]) {
    await form.locator(`[name="${name}"]`).fill(value)
  }
  await paste(image, `  ${link}`)
  await expect(image).toHaveJSProperty("value", `  ${link.slice(0, 256)}`)
  await expect(line).toHaveText(linkTooLong)
  await press.click()
  await expect(pressNote).toHaveText(linkTooLong)
  expect(await sentByStandIn(page)).toEqual([])

  // 3,999 letters and a line break, which reaches the site as one character.
  const longest = `${"w".repeat(1_999)}\n${"w".repeat(2_000)}`
  await form.locator('[name="kind"]').selectOption("decision")
  await paste(text, longest)
  await expect(text).toHaveJSProperty("value", longest)
  await expect(line).toContainText("A decision; nothing moves.")
  await press.click()
  await expect.poll(async () => (await sentByStandIn(page)).length).toBe(1)
  const [{transaction}] = await sentByStandIn(page)
  expect(transaction.to.toLowerCase()).toBe(votesContract)
  expect(transaction.data.startsWith(proposeFor(key))).toBe(true)
  // The words' hash follows the Key in the call (VoteSteps.content_hash/1).
  expect(transaction.data.slice(10 + 64, 10 + 128)).toBe(bytesToHex(keccak_256(utf8ToBytes(longest))))
  expect(errors).toEqual([])
})
