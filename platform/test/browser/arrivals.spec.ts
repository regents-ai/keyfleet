import {existsSync, readFileSync} from "node:fs"
import {expect, test} from "@playwright/test"

// Where a visit came from and where it stopped (KeyfleetWeb.VisitLog): a
// stranger who follows a link from an AI answer writes one `arrival` line naming
// that source before its first page line, and a press on Sign in writes the
// journey's first step. Opening another page in the same visit adds no arrival.

type Line = {metadata: {visit?: string; event?: {name: string; where: string; outcome?: string}}}

function lines(visit: string): Line[] {
  const file = "tmp/walk-lines.jsonl"
  if (!existsSync(file)) return []
  return readFileSync(file, "utf8")
    .split("\n")
    .filter(text => text.includes(visit))
    .map(text => JSON.parse(text) as Line)
    .filter(line => line.metadata.visit === visit && line.metadata.event)
}

const told = (line: Line) =>
  [line.metadata.event!.name, line.metadata.event!.where, line.metadata.event!.outcome].filter(Boolean).join(" ")

test("a visit from an AI answer arrives once, then presses Sign in", async ({page, context, hasTouch}) => {
  await page.goto("/classic/1", {referer: "https://chatgpt.com/c/a-private-chat"})
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  const visit = (await context.cookies()).find(cookie => cookie.name === "_visit")!.value

  await expect.poll(() => lines(visit).map(told)).toContain("page /classic/1")
  const first = lines(visit).map(told)
  expect(first.filter(line => line.startsWith("arrival"))).toEqual(["arrival /classic/1 chatgpt"])
  expect(first.indexOf("arrival /classic/1 chatgpt")).toBeLessThan(first.indexOf("page /classic/1"))

  const signIn = page.locator("#account-control [data-account-target='sign-in']")
  await (hasTouch ? signIn.tap() : signIn.click())
  await page.evaluate(() => window.dispatchEvent(new PageTransitionEvent("pagehide")))
  await expect.poll(() => lines(visit).map(told)).toContain("step sign_in_opened")

  await page.goto("/", {referer: "https://www.google.com/"})
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  await expect.poll(() => lines(visit).map(told)).toContain("page /")

  const all = lines(visit).map(told)
  expect(all.filter(line => line.startsWith("arrival"))).toHaveLength(1)
  expect(JSON.stringify(lines(visit))).not.toContain("a-private-chat")
})

// A browser that sends Global Privacy Control starts no visit: no `_visit`
// cookie and no visit on the page, so none of its lines can be grouped into a
// visit, and its Sign in press still reaches the site.
test("a visit that asks not to be tracked starts no visit", async ({page, context, hasTouch}) => {
  await page.setExtraHTTPHeaders({"Sec-GPC": "1"})
  await page.goto("/classic/1", {referer: "https://chatgpt.com/c/a-private-chat"})
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  expect((await context.cookies()).map(cookie => cookie.name)).not.toContain("_visit")
  await expect(page.locator("meta[name='regent-visit']")).toHaveCount(0)

  const reported = page.waitForResponse(response => new URL(response.url()).pathname === "/visit-log")
  const signIn = page.locator("#account-control [data-account-target='sign-in']")
  await (hasTouch ? signIn.tap() : signIn.click())
  await page.evaluate(() => window.dispatchEvent(new PageTransitionEvent("pagehide")))
  expect((await reported).status()).toBe(204)
  expect((await context.cookies()).map(cookie => cookie.name)).not.toContain("_visit")
})
