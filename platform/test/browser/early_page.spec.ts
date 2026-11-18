import {randomBytes} from "node:crypto"
import {expect, test, type Page} from "@playwright/test"
import {rollerOnly} from "./support/early"
import {call, setSurfaces} from "./support/fleet_chain"

// The early-access page is open only while the site is closed; once it opens,
// /early sends visitors to the homepage. So this runs with the chain's server,
// which can close the site.
test.beforeEach(() => setSurfaces(false))
test.afterEach(() => setSurfaces(true))

// Every request the page makes, and whether anything on it is wider than the window.
async function openEarly(page: Page) {
  const requested: string[] = []
  page.on("request", request => requested.push(request.url()))
  await page.goto("/early")
  await page.waitForLoadState("networkidle")
  const sideways = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth)
  return {requested, sideways}
}

for (const viewport of [{width: 375, height: 812}, {width: 1440, height: 900}]) {
  test(`the early-access page fits ${viewport.width}px and refuses an unreadable address, with only the key roller and nothing of sign-in`, async ({page}) => {
    await page.setViewportSize(viewport)
    const {requested, sideways} = await openEarly(page)

    expect(sideways).toBe(false)
    expect(requested.filter(url => /privy/i.test(url))).toEqual([])
    expect(rollerOnly(requested)).toBe(true)
    await expect(page.getByRole("heading", {name: "Attach your personal agent to a crew that runs itself.", level: 1})).toBeVisible()
    await expect(page.getByRole("link", {name: "Follow on X"})).toHaveAttribute("href", "https://x.com/regents_sh")
    await expect(page.getByRole("link", {name: "Follow on X"})).toBeVisible()
    await expect(page.locator("#early-tech-stack .rg-disclosure-title")).toHaveText("Tech stack")
    await expect(page.locator("#early-tech-stack li")).toHaveCount(4)

    const email = page.getByLabel("Email")
    await email.fill("not an address")
    await page.getByRole("button", {name: "Tell me when it opens"}).click()
    await expect(page.getByText("Enter an email address, like name@example.com.")).toBeVisible()
    await expect(email).toHaveValue("not an address")
    expect(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth)).toBe(false)
  })
}

// The addresses on the list that start with `start`.
function kept(start: string) {
  const rows = call("query!", [`select email from keyfleet_app.early_signups where email like '${start}%' order by email`], "Keyfleet.Repo")
  return [...rows.matchAll(new RegExp(`\\["(${start}[^"]*)"\\]`, "g"))].map(match => match[1])
}

test("an address its box cut after the spaces before it is refused and never kept; one that fits is", async ({page}) => {
  const start = `e${randomBytes(4).toString("hex")}`
  const email = page.getByLabel("Email")
  const send = () => page.getByRole("button", {name: "Tell me when it opens"}).click()
  // 254 characters, the most an address takes, with three spaces before it:
  // the box holds 256, so it keeps the spaces and cuts the address's end.
  const longest = `${start}a@example.${"a".repeat(254 - `${start}a@example.`.length)}`
  const typed = `   ${longest}`

  await page.goto("/early")
  await email.focus()
  await page.keyboard.insertText(typed)
  await send()
  await expect(page.getByText("That address is too long: 254 characters at most.")).toBeVisible()
  await expect(email).toHaveValue(typed.slice(0, 256))

  const honest = `${start}b@example.com`
  await email.fill(`  ${honest} `)
  await send()
  await expect(page.getByText("You're on the list. We'll email you when Keyfleet opens.")).toBeVisible()
  expect(kept(start)).toEqual([honest])
})
