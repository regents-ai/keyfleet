import {expect, test} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {call, prepareFleet, sellKey} from "./support/fleet_chain"

// A member opens the page Keyfleet keeps of a notebook's background run from
// its address on the fleet's notebook host, as a result link on the workspace
// sends them. The host has no notebook sign-in for them yet, so Keyfleet signs
// them in to the fleet's notebooks and brings them back, and the host answers
// with Keyfleet's own copy of the page, in a sandbox where its scripts run.
// The fleet's hub is a stand-in (`Keyfleet.BrowserWorkspace`), asked only to
// let the member in. The page (test/support/fixtures/notebook_pages/walk.html)
// is written by hand: a page marimo exports draws its cells with a frontend it
// loads from cdn.jsdelivr.net, and the walk reads nothing from outside the
// machine.
//
// The notebook host's address names no port, so Chromium is told to find the
// fleet's notebook host at the walk's server.
const port = process.env.PORT || "4502"
const fleet = "fleet_tech_accelerant"
const notebooks = "fleet-tech-accelerant.notebooks.localhost"
// Signed in as "valid" (test/support/test_privy_verifier.ex).
const member = "0x1111111111111111111111111111111111111111"

test.use({launchOptions: {args: [`--host-resolver-rules=MAP ${notebooks} 127.0.0.1:${port}`]}})

let result: string

test.beforeAll(() => {
  prepareFleet(fleet)
  sellKey(fleet, member)
  call("start_hub!", [fleet], "Keyfleet.BrowserWorkspace")
  result = call("keep_page!", [fleet, "walk.html"], "Keyfleet.BrowserWorkspace")
})

test("a member opens a kept run page, moves through it with the keyboard, and it fits the screen", async ({page}) => {
  const hosts = new Set<string>()
  page.on("request", request => hosts.add(new URL(request.url()).host))
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()

  const kept = page.waitForResponse(response => response.url() === result && response.status() === 200)
  await page.goto(result)
  const headers = (await kept).headers()
  await expect(page).toHaveURL(result)
  expect(headers["content-security-policy"]).toBe("sandbox allow-scripts")
  expect(headers["x-content-type-options"]).toBe("nosniff")

  // Every cell shows, and the slider's own script has drawn what it sets.
  const cells = page.locator("[data-cell-id]")
  await expect(cells).toHaveCount(6)
  for (const cell of await cells.all()) await expect(cell).toBeVisible()
  await expect(page.locator("#rows")).toHaveText("54 rows of 4")

  // The keys scroll the page to its last cell and back.
  await page.keyboard.press("End")
  await expect(cells.last()).toBeInViewport()
  await expect.poll(() => page.evaluate(() => window.scrollY)).toBeGreaterThan(0)
  await page.keyboard.press("Home")
  await expect.poll(() => page.evaluate(() => window.scrollY)).toBe(0)

  // Tab reaches the wide table, whose arrows scroll it sideways, then the
  // slider, whose arrows change it.
  const table = page.getByRole("region", {name: "Boats by harbour"})
  await page.keyboard.press("Tab")
  await expect(table).toBeFocused()
  await page.keyboard.press("ArrowRight")
  await expect.poll(() => table.evaluate(element => element.scrollLeft)).toBeGreaterThan(0)
  await page.keyboard.press("Tab")
  await expect(page.locator("#per-row")).toBeFocused()
  await page.keyboard.press("ArrowRight")
  await expect(page.locator("#rows")).toHaveText("43 rows of 5")

  // Only the table scrolls sideways; the page fits the screen's width.
  const width = await page.evaluate(() => document.documentElement.scrollWidth)
  expect(width).toBeLessThanOrEqual(page.viewportSize()!.width)

  // Nothing was asked of anywhere but this site and the fleet's notebook host.
  expect([...hosts].filter(host => host !== `localhost:${port}` && host !== notebooks)).toEqual([])
})
